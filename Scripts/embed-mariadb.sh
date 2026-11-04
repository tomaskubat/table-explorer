#!/bin/bash
set -eu
source_lib=/opt/homebrew/opt/mariadb-connector-c/lib/libmariadb.3.dylib
if [[ ! -f "$source_lib" ]]; then
    echo "error: Install the Apple Silicon build dependency with brew install mariadb-connector-c." >&2
    exit 1
fi
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$frameworks"
stage="$(mktemp -d "$TARGET_TEMP_DIR/mariadb.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
# The linker reads the relocated install name from this copy. Each dependent
# dylib resolves its peers in the same directory on a Mac without Homebrew.
copy_library() {
    local source="$1" name target dependency
    name="$(basename "$source")"
    target="$stage/$name"
    [[ -f "$target" ]] && return 0
    cp -f "$source" "$target"
    chmod u+w "$target"
    lipo "$target" -verify_arch arm64
    install_name_tool -id "@rpath/$name" "$target"
    while read -r dependency; do
        [[ "$(basename "$dependency")" == "$name" ]] && continue
        copy_library "$dependency"
        install_name_tool -change "$dependency" "@loader_path/$(basename "$dependency")" "$target"
    done < <(otool -L "$source" | awk '/^[[:space:]]+\/opt\/homebrew\// {print $1}')
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$target"
}
copy_library "$source_lib"
for dylib in "$stage"/*.dylib; do mv -f "$dylib" "$frameworks/"; done
ln -sfn libmariadb.3.dylib "$frameworks/libmariadb.dylib"
licenses="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Licenses"
mkdir -p "$licenses"
cp /opt/homebrew/opt/mariadb-connector-c/COPYING.LIB "$licenses/MariaDB-Connector-C.txt"
ssl_prefix="$(otool -L "$source_lib" | awk '/^[[:space:]]+.*\/libssl\./ {sub(/\/lib\/libssl.*/, "", $1); print $1; exit}')"
cp "$ssl_prefix/LICENSE.txt" "$licenses/OpenSSL.txt"
