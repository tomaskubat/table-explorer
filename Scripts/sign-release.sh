#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tag=${1:?Pass the tag used for package-release.sh}
[[ $tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || exit 1
version=${tag#v}
root="$PWD/.build/distribution"
release="$root/$tag"
archive="ConnectionBrowser-$version-arm64.zip"
repo=https://github.com/tomaskubat/table-explorer
tools="$root/packages/artifacts/sparkle/Sparkle/bin"
feed=$(mktemp -d "$root/feed.XXXXXX")
trap 'rm -rf "$feed"' EXIT
cp "$release/$archive" "$feed/"
args=(--maximum-deltas 0 --download-url-prefix "$repo/releases/download/$tag/" --link "$repo/releases/tag/$tag" "$feed")
if [[ -n ${SPARKLE_PRIVATE_KEY:-} ]]; then
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" --ed-key-file - "${args[@]}"
elif [[ ${GITHUB_ACTIONS:-} == true ]]; then
    echo "Set the repository secret SPARKLE_PRIVATE_KEY." >&2; exit 1
else
    "$tools/generate_appcast" --account local.connectionbrowser.app "${args[@]}"
fi
swift Scripts/verify-update.swift "$feed" "$version" Configuration/sparkle-public-key.txt
mv "$feed/appcast.xml" "$release/appcast.xml"
(cd "$release" && shasum -a 256 "$archive" appcast.xml > SHA256SUMS.txt)
