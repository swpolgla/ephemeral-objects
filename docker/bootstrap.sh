#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_dir="$root_dir/runtime"

for directory in \
    app/objects app/logs \
    postgres/data postgres/logs \
    caddy/data caddy/config caddy/logs \
    cap/data cap/logs \
    valkey/data valkey/logs \
    secrets
do
    mkdir -p "$runtime_dir/$directory"
done

generate_secret() {
    path=$1
    if [ ! -s "$path" ]; then
        if command -v openssl >/dev/null 2>&1; then
            openssl rand -hex 32 > "$path"
        else
            LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | dd bs=32 count=1 2>/dev/null > "$path"
        fi
    fi
    chmod 444 "$path"
}

chmod 700 "$runtime_dir/secrets"
generate_secret "$runtime_dir/secrets/postgres_password"
generate_secret "$runtime_dir/secrets/cap_admin_key"

if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" -eq 0 ]; then
    chown -R 10001:10001 "$runtime_dir/app"
    chown -R 70:70 "$runtime_dir/postgres"
    chown -R 1000:1000 "$runtime_dir/caddy" "$runtime_dir/cap" "$runtime_dir/valkey"
fi

printf '%s\n' "Runtime directories and secrets are ready in $runtime_dir"
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "Run this script as root if containers report bind-mount permission errors."
fi
