#!/bin/sh
set -eu
umask 077
fixture_dir="$(cd "$(dirname "$0")" && pwd)"
keys="$fixture_dir/../../../.build/SSHFixture"
mkdir -p "$keys"
for name in server client; do
    if [ ! -f "$keys/$name" ]; then
        ssh-keygen -q -t ed25519 -N '' -f "$keys/$name"
    fi
done
awk '{ print "[127.0.0.1]:33463,[127.0.0.1]:33464 " $1 " " $2 }' "$keys/server.pub" > "$keys/known_hosts"
set --
if docker network inspect connectionbrowser-secure-uitest_default >/dev/null 2>&1; then
    set -- --profile tls
fi
docker compose -f "$fixture_dir/compose.yaml" "$@" up -d --build
