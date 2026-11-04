#!/bin/bash
set -eu
umask 077
fixture_dir="$(cd "$(dirname "$0")" && pwd)"
cert_dir="$fixture_dir/../../../.build/TLSFixture"
mkdir -p "$cert_dir"
set --
if ! openssl x509 -checkend 86400 -noout -in "$cert_dir/server.crt" >/dev/null 2>&1; then
    set -- --force-recreate
    openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=Connection Browser Test CA" \
        -keyout "$cert_dir/ca.key" -out "$cert_dir/ca.crt"
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=localhost" \
        -keyout "$cert_dir/server.key" -out "$cert_dir/server.csr"
    printf '%s\n' 'subjectAltName=DNS:localhost,IP:127.0.0.1' 'extendedKeyUsage=serverAuth' > "$cert_dir/server.ext"
    openssl x509 -req -days 7 -in "$cert_dir/server.csr" -CA "$cert_dir/ca.crt" -CAkey "$cert_dir/ca.key" \
        -CAcreateserial -extfile "$cert_dir/server.ext" -out "$cert_dir/server.crt"
    # Only these three files are mounted into the ephemeral server. Their
    # containing directory remains private on the Mac.
    chmod 644 "$cert_dir/ca.crt" "$cert_dir/server.crt" "$cert_dir/server.key"
fi
openssl x509 -in "$cert_dir/server.crt" -noout -sha256 -fingerprint | sed 's/.*=//' > "$cert_dir/fingerprint"
docker compose -f "$fixture_dir/secure-compose.yaml" up -d --wait "$@"
