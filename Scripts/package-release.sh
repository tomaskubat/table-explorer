#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tag=${1:?Pass a release tag such as v0.1.0}
[[ $tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "Invalid release tag: $tag" >&2; exit 1; }
version=${tag#v}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
root="$PWD/.build/distribution"
packages="$root/packages"
public_key=$(cat Configuration/sparkle-public-key.txt)
[[ $public_key =~ ^[A-Za-z0-9+/]{43}=$ ]]
xcodebuild -project TableExplorer.xcodeproj -scheme TableExplorer -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$root/Derived" \
    -clonedSourcePackagesDirPath "$packages" -onlyUsePackageVersionsFromResolvedFile \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$version" CONNECTION_BROWSER_UPDATE_KEY="$public_key" build

work=$(mktemp -d "$root/package.XXXXXX")
trap 'rm -rf "$work"' EXIT
app="$work/TableExplorer.app"
ditto "$root/Derived/Build/Products/Release/TableExplorer.app" "$app"
info="$app/Contents/Info.plist"
[[ $(plutil -extract CFBundleVersion raw "$info") == "$version" ]]
[[ $(plutil -extract CFBundleShortVersionString raw "$info") == "$version" ]]
[[ $(plutil -extract SUPublicEDKey raw "$info") == "$public_key" ]]
[[ $(plutil -extract SUFeedURL raw "$info") == https://github.com/tomaskubat/table-explorer/releases/latest/download/appcast.xml ]]
[[ $(plutil -extract CFBundleIdentifier raw "$info") == local.connectionbrowser.app ]]
for property in CFBundleName CFBundleDisplayName CFBundleExecutable; do
    [[ $(plutil -extract "$property" raw "$info") == TableExplorer ]]
done
[[ $(plutil -extract LSMinimumSystemVersion raw "$info") == 26.0 ]]
[[ $(lipo -archs "$app/Contents/MacOS/TableExplorer") == arm64 ]]
frameworks="$app/Contents/Frameworks"
test -f "$frameworks/libmariadb.3.dylib"
test -x "$app/Contents/Resources/ssh-tunnel"
test -x "$app/Contents/Resources/ssh-askpass"
for binary in "$app/Contents/MacOS/TableExplorer" "$frameworks"/*.dylib; do
    lipo -verify_arch arm64 "$binary"
    otool -L "$binary" | awk 'NR>1 {print $1}' > "$work/links"
    while IFS= read -r link; do
        case "$link" in
            /usr/lib/*|/System/Library/*) ;;
            @rpath/*) test -f "$frameworks/${link#@rpath/}" ;;
            @loader_path/*) test -f "$(dirname "$binary")/${link#@loader_path/}" ;;
            *) echo "Nonportable dependency: $link" >&2; exit 1 ;;
        esac
    done < "$work/links"
done
cp "$packages/artifacts/sparkle/Sparkle/LICENSE" "$app/Contents/Resources/Licenses/Sparkle.txt"
sparkle="$frameworks/Sparkle.framework"
for helper in "$sparkle"/Versions/B/XPCServices/*.xpc "$sparkle/Versions/B/Updater.app" "$sparkle/Versions/B/Autoupdate"; do
    codesign --force --sign - --options=0 "$helper"
done
codesign --force --sign - --options=0 "$sparkle"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

archive="TableExplorer-$version-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$archive"
mkdir "$work/unpacked"
ditto -x -k "$work/$archive" "$work/unpacked"
codesign --verify --deep --strict "$work/unpacked/TableExplorer.app"
mkdir -p "$root/$tag"
mv "$work/$archive" "$root/$tag/$archive"
