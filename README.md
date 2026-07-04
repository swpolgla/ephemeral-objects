# ephemeral-objects
End to End encrypted temp file hosting

## Docker Compose

The Compose stack runs the Swift application, PostgreSQL, Caddy, Cap, and
Valkey. Mutable data and supported file logs are bind-mounted beneath the
ignored `runtime/` directory rather than stored in anonymous Docker volumes.

```sh
cp .env.example .env
./docker/bootstrap.sh
docker compose up --build -d
```

Set `APP_HOST` and `PUBLIC_ORIGIN` in `.env` before a public deployment. Caddy
serves the application at `/` and strips `/captcha/` before forwarding requests
to Cap. Cap's dashboard is deliberately not routed publicly; start its
localhost-only tunnel when administration is needed:

```sh
docker compose --profile admin up -d cap-admin
```

The dashboard is then available at `http://127.0.0.1:3000`. PostgreSQL and
Valkey have no host-published ports.

Create a site key in the Cap dashboard, set its public key as `CAP_SITE_KEY` in
`.env`, and copy its secret key (not the dashboard admin key) into
`runtime/secrets/cap_site_secret`. The public challenge endpoint is exposed to
the browser as `/captcha/<site-key>/`; the application validates its single-use
tokens against Cap's internal `/siteverify` endpoint before reading an upload
body.

On Linux, run `sudo ./docker/bootstrap.sh` once if bind-mounted directories
need their container UID ownership initialized. Docker Desktop handles bind
mount ownership differently and normally does not require this step.

PostgreSQL and Caddy write native logs beneath `runtime/`. Valkey writes to
`runtime/valkey/logs`; Vapor and Cap use stdout/stderr and remain available
through `docker compose logs`.

## Object retention

PostgreSQL is the source of truth for stored objects. Each successful upload
records its server-generated UUID, sanitized original filename, optional file
extension, media type, actual byte size, SHA-256 digest, upload time, lifecycle
state, and remaining download count. Files on disk are named only by the
server-generated UUID.

The limits in the untracked root `config.json` control object behavior. Start
from `config.example.json` when setting up a new checkout.

- `maximum_file_size` is the maximum streamed size in bytes.
- `maximum_storage_duration` is the retention period in days. Changes apply to
  existing objects during the next sweep.
- `maximum_downloads` is the initial download allowance.
- `maximum_upload_time` is the wall-clock upload timeout in seconds.
- `maximum_concurrent_uploads` bounds simultaneous upload streams.

Downloads are attachments and consume their allowance when streaming begins.
Range requests are not supported. The final download schedules immediate
deletion. A database-coordinated reconciliation pass also runs at startup and
once per hour to remove expired, exhausted, incomplete, and orphaned objects.
