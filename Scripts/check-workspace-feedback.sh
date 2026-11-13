#!/bin/bash
# Exercise the native workspace against a private SQLite database.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p .build/WorkspaceFeedbackCompilerCache
sources=()
for file in TableExplorer/*.swift; do
    [[ "$file" == */TableExplorerApp.swift ]] || sources+=("$file")
done
connector=$(brew --prefix mariadb-connector-c)
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path .build/WorkspaceFeedbackCompilerCache \
    -I Drivers -Xcc "-I$connector/include/mariadb" "-L$connector/lib" -lmariadb -lsqlite3 \
    -o "$work/check" Tests/QA/WorkspaceFeedback.swift "${sources[@]}"
CONNECTION_BROWSER_LIBRARY="$work/library" "$work/check" "$@"
