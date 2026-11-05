#!/bin/bash
# Optional for GitHub-hosted releases. Local releases use the login keychain.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || exit 1
: "${RUNNER_TEMP:?}" "${TABLEEXPLORER_SIGNING_P12:?Build on the signing Mac with make release, or configure this CI secret.}" "${TABLEEXPLORER_SIGNING_PASSWORD:?Missing CI certificate password.}"
umask 077
file=$(mktemp "$RUNNER_TEMP/table-explorer.XXXXXX")
trap 'rm -f "$file"' EXIT
keychain="$RUNNER_TEMP/table-explorer-signing.keychain-db"
password=$(openssl rand -hex 32)
echo "::add-mask::$password"
printf '%s' "$TABLEEXPLORER_SIGNING_P12" | /usr/bin/base64 -D > "$file"
security create-keychain -p "$password" "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$file" -k "$keychain" -f pkcs12 -P "$TABLEEXPLORER_SIGNING_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
chains=()
while IFS= read -r path; do chains+=("$path"); done < <(security list-keychains -d user | sed 's/^[[:space:]]*"//;s/"$//')
security list-keychains -d user -s "$keychain" "${chains[@]}"
Scripts/app-signature.sh identity
