#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case ${1:-} in
    ""|--run) ;;
    *) echo "Usage: $0 [--run]" >&2; exit 2 ;;
esac
(( $# <= 1 )) || exit 2
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
Scripts/app-signature.sh identity
build_dir="$PWD/.build/local"
xcodebuild -quiet -project TableExplorer.xcodeproj -scheme TableExplorer -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$build_dir" \
    -clonedSourcePackagesDirPath "$PWD/.build/distribution/packages" \
    -onlyUsePackageVersionsFromResolvedFile build
app="$build_dir/Build/Products/Debug/TableExplorer.app"
Scripts/app-signature.sh verify-app "$app"
printf 'Built and verified: %s\n' "$app"
if [[ ${1:-} == --run ]]; then open "$app"; fi
