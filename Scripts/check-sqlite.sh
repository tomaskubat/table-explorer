#!/bin/bash
# Build the production Swift driver into a console test. Never open a user database.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p .build/QACompilerCache
sources=()
for file in TableExplorer/*.swift; do
  [[ "$file" == */TableExplorerApp.swift ]] || sources+=("$file")
done
connector=$(brew --prefix mariadb-connector-c)
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path .build/QACompilerCache \
    -I Drivers -Xcc "-I$connector/include/mariadb" "-L$connector/lib" -lmariadb -lsqlite3 \
    -o "$work/check" Tests/QA/SQLiteChecks.swift "${sources[@]}"
sqlite3 -batch -bail "$work/test.sqlite" < Tests/Fixtures/SQLite/seed.sql
"$work/check" "$work/test.sqlite"
sqlite3 "$work/test.sqlite" 'SELECT id,nazev,quote(poznamka) FROM mesto ORDER BY id'
