## pg

Self hostable postgres with continuous backups and point-in-time recovery.

## Kamal example
```yaml
accessories:
  db:
    image: ghcr.io/frankvd/pg
    host: 10.0.0.1
    port: "5432:5432"
    env:
      clear:
        POSTGRES_USER: postgres
        AWS_BUCKET: my-postgres-backups-bucket
        AWS_ENDPOINT_URL: https://s3.eu-central-1.amazonaws.com
      secret:
        - POSTGRES_PASSWORD
        - AWS_ACCESS_KEY_ID
        - AWS_SECRET_ACCESS_KEY
    volumes:
      - pgdata:/var/lib/postgresql/data
```
