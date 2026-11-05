#!/bin/bash
# Sign from the inside out. Verify the signer as well as bundle integrity.
set -euo pipefail
cd "$(dirname "$0")/.."
cert=Configuration/table-explorer-signing.pem
fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
[[ $fingerprint =~ ^[[:xdigit:]]{40}$ ]] || exit 1
leaf="certificate leaf = H\"$fingerprint\""

case ${1:-} in
    identity)
        openssl x509 -in "$cert" -checkend 0 -noout >/dev/null
        # A self-signed certificate need not be a trusted root to sign code.
        identities=$(security find-identity -p codesigning)
        if ! awk -v fp="$fingerprint" '$2 == fp { found=1 } END { exit !found }' <<< "$identities"; then
            echo "The TableExplorer signing identity ($fingerprint) is missing. Build on the signing Mac; no ad hoc release will be produced." >&2
            exit 1
        fi
        ;;
    sign|verify)
        app=${2:?Supply an absolute path to TableExplorer.app}
        frameworks="$app/Contents/Frameworks"
        sparkle="$frameworks/Sparkle.framework"
        parts=()
        for lib in "$frameworks"/*.dylib; do
            [[ -L "$lib" ]] || parts+=("$lib")
        done
        parts+=("$sparkle"/Versions/B/XPCServices/*.xpc "$sparkle/Versions/B/Updater.app" "$sparkle/Versions/B/Autoupdate" "$sparkle" "$app")
        for part in "${parts[@]}"; do
            if [[ $1 == sign ]]; then
                codesign --force --options=0 --timestamp=none --sign "$fingerprint" "$part"
            else
                codesign --verify --strict -R="$leaf" "$part"
            fi
        done
        if [[ $1 == verify ]]; then
            codesign --verify --deep --strict -R="identifier \"local.connectionbrowser.app\" and $leaf" "$app"
        fi
        ;;
    *) echo "Usage: $0 identity | sign /path/to/TableExplorer.app | verify /path/to/TableExplorer.app" >&2; exit 2 ;;
esac
