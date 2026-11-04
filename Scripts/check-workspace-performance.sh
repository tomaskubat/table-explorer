#!/bin/bash
# Measure a native workspace window on the current display, using a disposable SQLite catalog.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p .build/QACompilerCache
sources=()
for file in ConnectionBrowser/*.swift; do
    [[ "$file" == */ConnectionBrowserApp.swift ]] || sources+=("$file")
done
connector=$(brew --prefix mariadb-connector-c)
xcrun swiftc -O -whole-module-optimization -num-threads 8 -swift-version 6 -parse-as-library \
    -module-cache-path .build/QACompilerCache -I Drivers -Xcc "-I$connector/include/mariadb" \
    "-L$connector/lib" -lmariadb -lsqlite3 -o "$work/probe" Tests/QA/WorkspacePerformance.swift "${sources[@]}"
CONNECTION_BROWSER_LIBRARY="$work/library" "$work/probe"
