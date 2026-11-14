#!/bin/bash
# Check version continuity and reject ad-hoc signing without accessing saved passwords.
set -euo pipefail
cd "$(dirname "$0")/../.."
app=${1:?Supply the signed local TableExplorer.app}
reference=${2:-}
Scripts/app-signature.sh verify-app "$app"
printf 'PASS: local app matches the release certificate and identifier\n'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fingerprint=$(openssl x509 -in Configuration/table-explorer-signing.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)

requirement() {
    local result
    result=$(codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p')
    [[ -n $result ]] || return 1
    printf '%s\n' "$result"
}
compatible() {
    local first second
    first=$(requirement "$1")
    second=$(requirement "$2")
    codesign --verify --strict -R="$first" "$2"
    codesign --verify --strict -R="$second" "$1"
}

adhoc="$work/adhoc/TableExplorer.app"
ditto "$app" "$adhoc"
codesign --force --options=0 --timestamp=none --sign - "$adhoc"
codesign --verify --deep --strict "$adhoc"
if Scripts/app-signature.sh verify-app "$adhoc" >"$work/adhoc-check.log" 2>&1; then
    echo 'FAIL: an ad-hoc build passed the local signing check' >&2
    exit 1
fi
printf 'PASS: an otherwise valid ad-hoc build is rejected\n'

updated="$work/updated/TableExplorer.app"
ditto "$app" "$updated"
version=$(plutil -extract CFBundleVersion raw "$updated/Contents/Info.plist")
if [[ $version == 9.9.9 ]]; then version=9.9.8; else version=9.9.9; fi
plutil -replace CFBundleVersion -string "$version" "$updated/Contents/Info.plist"
codesign --force --options=0 --timestamp=none --sign "$fingerprint" "$updated"
Scripts/app-signature.sh verify-app "$updated"
compatible "$app" "$updated"
printf 'PASS: a different version retains mutually compatible code identity\n'

if [[ -n $reference ]]; then
    Scripts/app-signature.sh verify-app "$reference"
    compatible "$app" "$reference"
    printf 'PASS: the local build and released app have mutually compatible code identity\n'
fi
