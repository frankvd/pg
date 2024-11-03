FROM postgres:17

RUN apt-get update && apt-get install -y \
    barman-cli-cloud \
    uuid-runtime \
    cron \
    supervisor \
    && rm -rf /var/lib/apt/lists/*

RUN cat > /etc/postgresql/pg_hba.conf <<EOF
local   all             all                                     trust
host    all             all             0.0.0.0/0              scram-sha-256
host    replication     all             0.0.0.0/0              scram-sha-256
EOF

RUN cat > /usr/local/bin/backup.sh <<'EOF'
#!/bin/bash
set -e

: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=$POSTGRES_USER}"
: "${BACKUP_RETENTION:='RECOVERY WINDOW OF 7 DAYS'}"

INSTANCE_ID=$(< /etc/postgresql/instance_id)

su - postgres -c "barman-cloud-backup -z -e AES256 \
    --cloud-provider aws-s3 \
    -U ${POSTGRES_USER} \
    s3://${AWS_BUCKET} \
    ${INSTANCE_ID}"

su - postgres -c "barman-cloud-backup-delete \
    --cloud-provider aws-s3 \
    -r ${BACKUP_RETENTION} \
    s3://${AWS_BUCKET} \
    ${INSTANCE_ID}"

echo "Backup completed at $(date)"
EOF

RUN cat > /usr/local/bin/restore.sh <<'EOF'
#!/bin/bash
set -e

# Initialize required environment variables
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=$POSTGRES_USER}"
: "${PGDATA:=/var/lib/postgresql/data}"


if [ -z "$BACKUP_ID" ]; then
    echo "Error: Backup ID not provided"
    exit 1
fi

if [ "$(ls -A ${PGDATA})" ]; then
    echo "Error: Cannot restore a backup because PGDATA is not empty"
    exit 1
fi

echo "restore_command = 'barman-cloud-wal-restore s3://${AWS_BUCKET}/ ${BACKUP_INSTANCE} %f %p'" >> /etc/postgresql/postgresql.conf

su - postgres -c "barman-cloud-restore \
    --cloud-provider aws-s3 \
    s3://${AWS_BUCKET} \
    ${BACKUP_INSTANCE} \
    ${BACKUP_ID} \
    \"${PGDATA}\""

if [ -n "$RECOVERY_TARGET_TIME" ]; then
    cat > "${PGDATA}/recovery.signal" <<RECOVERY_EOF
recovery_target_time = '${RECOVERY_TARGET_TIME}'
recovery_target_action = 'promote'
RECOVERY_EOF
fi
EOF

RUN cat > /etc/supervisor/conf.d/supervisord.conf <<'EOF'
[supervisord]
nodaemon=true
user=root
logfile=/dev/stdout
logfile_maxbytes=0
pidfile=/var/run/supervisord.pid

[program:postgresql]
command=/usr/local/bin/docker-entrypoint.sh postgres -c config_file=/etc/postgresql/postgresql.conf -c hba_file=/etc/postgresql/pg_hba.conf
user=postgres
autorestart=true
priority=1
redirect_stderr=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0

[program:cron]
command=/usr/sbin/cron -f
autostart=true
autorestart=true
priority=2
redirect_stderr=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
EOF

RUN cat > /usr/local/bin/init.sh <<'EOF'
#!/bin/bash
set -e

: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=$POSTGRES_USER}"
: "${PGDATA:=/var/lib/postgresql/data}"
: "${BACKUP_SCHEDULE:=0 0 * * *}"

if [ ! -f "/etc/postgresql/instance_id" ]; then
  echo "${POSTGRES_DB}_$(date +%Y%m%d_%H%M%S)_$(openssl rand -hex 4)" > /etc/postgresql/instance_id
fi
export INSTANCE_ID=$(< /etc/postgresql/instance_id)
cat >  /etc/environment <<FOE
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_USER=${POSTGRES_USER}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
AWS_BUCKET=${AWS_BUCKET}
AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL}
PGDATA=${PGDATA}
FOE

if [ ! -f "/etc/postgresql/postgresql.conf" ]; then
  cat > /etc/postgresql/postgresql.conf <<FOE
listen_addresses = '*'
wal_level = replica
FOE
  if [ "$DISABLE_BACKUP" != "true" ]; then
    cat >> /etc/postgresql/postgresql.conf <<FOE
archive_mode = on
archive_command = 'barman-cloud-wal-archive -e AES256 -z s3://${AWS_BUCKET}/ ${INSTANCE_ID} %p'
archive_timeout = 60
FOE
    echo "Setting up backup schedule: $BACKUP_SCHEDULE"
    echo "$BACKUP_SCHEDULE /usr/local/bin/backup.sh >> /var/log/cron.log 2>&1" > /etc/cron.d/backup-cron
    chmod 0644 /etc/cron.d/backup-cron
    crontab /etc/cron.d/backup-cron
  fi
fi

if [ -n "$BACKUP_INSTANCE" ] && [ -n "$BACKUP_ID" ] && [ ! -f "${PGDATA}/postgresql.conf" ]; then
    /usr/local/bin/restore.sh
fi

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
EOF

RUN chmod +x /usr/local/bin/backup.sh \
    && chmod +x /usr/local/bin/restore.sh \
    && chmod +x /usr/local/bin/init.sh

ENTRYPOINT ["/usr/local/bin/init.sh"]
