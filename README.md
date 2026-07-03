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

On Linux, run `sudo ./docker/bootstrap.sh` once if bind-mounted directories
need their container UID ownership initialized. Docker Desktop handles bind
mount ownership differently and normally does not require this step.

PostgreSQL and Caddy write native logs beneath `runtime/`. Valkey writes to
`runtime/valkey/logs`; Vapor and Cap use stdout/stderr and remain available
through `docker compose logs`.
