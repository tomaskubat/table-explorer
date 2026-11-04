#!/bin/bash
# Exercise the local publisher against a bare Git remote and offline release assets.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export fixture real_git
real_git=$(command -v git)
git init -q --bare "$fixture/origin.git"
git init -q -b main "$fixture/work"
cd "$fixture/work"
mkdir -p Scripts "$fixture/bin"
cp "$repo/Makefile" .
cp "$repo/Scripts/release.sh" Scripts/
echo .build/ > .gitignore
git config user.name Fixture
git config user.email fixture@example.invalid
git remote add origin "$fixture/origin.git"
cat > Scripts/check-sqlite.sh <<'EOF'
#!/bin/sh
echo noisy-test-output
EOF
cat > Scripts/package-release.sh <<'EOF'
#!/bin/sh
mkdir -p ".build/distribution/$1"
echo fixture > ".build/distribution/$1/TableExplorer-${1#v}-arm64.zip"
EOF
cat > Scripts/sign-release.sh <<'EOF'
#!/bin/sh
[ -z "${FAIL_SIGN:-}" ] || { echo 'injected signing error' >&2; exit 9; }
cd ".build/distribution/$1" || exit 1
echo fixture > appcast.xml
shasum -a 256 "TableExplorer-${1#v}-arm64.zip" appcast.xml > SHA256SUMS.txt
EOF
cat > "$fixture/bin/git" <<'EOF'
#!/bin/sh
if [ "$*" = 'remote get-url --push origin' ]; then echo https://github.com/tomaskubat/table-explorer.git; else exec "$real_git" "$@"; fi
EOF
cat > "$fixture/bin/gh" <<'EOF'
#!/bin/bash
set -eu
case "$1 $2" in
  'api --paginate') if [[ -e $fixture/draft ]]; then printf 'v0.0.1\ttrue\tfalse\n'; fi ;;
  'release create') touch "$fixture/draft" ;;
  'release upload') cp .build/distribution/v0.0.1/* "$fixture"/ ;;
  'release view') if [[ $* == *isDraft* ]]; then echo true; else (cd "$fixture" && shasum -a 256 TableExplorer-*.zip appcast.xml SHA256SUMS.txt); fi ;;
  'release edit') rm "$fixture/draft" ;;
  'api repos/tomaskubat/table-explorer/commits/v0.0.1') git rev-parse HEAD ;;
  *) exit 1 ;;
esac
EOF
cat > "$fixture/bin/curl" <<'EOF'
#!/bin/bash
set -eu
while [[ $1 != https:* ]]; do shift; done
cp "$fixture/${1##*/}" "$3"
EOF
printf '#!/bin/sh\nexit 0\n' > "$fixture/bin/swift"
chmod +x Scripts/*.sh "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
git add . && git commit -qm fixture && git push -q origin main
if FAIL_SIGN=1 make release > "$fixture/fail" 2>&1; then exit 1; fi
grep -Fxq 'Sign update ... FAILED' "$fixture/fail"
! grep -q 'Create and push\|noisy-test-output\|injected signing error' "$fixture/fail" || exit 1
grep -q 'injected signing error' "$(sed -n 's/^Log: //p' "$fixture/fail")"
test -z "$(git tag)"
make release > "$fixture/pass"
test "$(grep -c ' \.\.\. PASS$' "$fixture/pass")" -eq 8
grep -Fxq 'Verify public update ... PASS' "$fixture/pass"
! grep -q 'noisy-test-output\|FAILED' "$fixture/pass" || exit 1
grep -q 'noisy-test-output' "$(sed -n 's/^Log: //p' "$fixture/pass")"
cat "$fixture/pass"
