#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "$*" >&2; exit 1; }
mode=${1:-}
input=${2:-}
version=${input#v}
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "Specify VERSION=X.Y.Z (for example VERSION=0.1.1)."
tag="v$version"
repo=tomaskubat/table-explorer
local_marker='Publish from local Mac'
out="$PWD/.build/distribution/$tag"
archive="ConnectionBrowser-$version-arm64.zip"
key="$PWD/Configuration/sparkle-public-key.txt"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

# Also identifies a draft left by an interrupted upload. Public releases are immutable here.
release_state() {
    gh api --paginate "repos/$repo/releases" --jq '.[] | [.tag_name, .draft, .prerelease] | @tsv' |
        python3 -c '
import re, sys
tag = sys.argv[1]
version = tuple(map(int, tag[1:].split(".")))
state = "new"
for line in sys.stdin:
    name, draft, prerelease = line.rstrip("\n").split("\t")
    if name == tag:
        if draft != "true":
            sys.exit(f"{tag} is already published.")
        state = "draft"
    if draft == prerelease == "false" and re.fullmatch(r"v\d+\.\d+\.\d+", name):
        if tuple(map(int, name[1:].split("."))) > version:
            sys.exit(f"{tag} must be newer than {name}.")
print(state)
' "$tag"
}

prepare() {
    Scripts/check-sqlite.sh
    Scripts/package-release.sh "$tag"
    Scripts/sign-release.sh "$tag"
}

verify_public() (
    set -e
    dest=$(mktemp -d)
    trap 'rm -rf "$dest"' EXIT
    url="https://github.com/$repo/releases"
    for file in "$archive" SHA256SUMS.txt; do
        curl -fsSL --retry 5 --retry-all-errors "$url/download/$tag/$file" -o "$dest/$file"
    done
    curl -fsSL --retry 5 --retry-all-errors "$url/latest/download/appcast.xml" -o "$dest/appcast.xml"
    swift Scripts/verify-update.swift "$dest" "$version" "$key"
    # Check only the two expected entries, never paths supplied by a downloaded manifest.
    (cd "$dest" && shasum -a 256 "$archive" appcast.xml) | cmp - "$dest/SHA256SUMS.txt"
    if [[ $mode != verify ]]; then cmp "$out/SHA256SUMS.txt" "$dest/SHA256SUMS.txt"; fi
)

clean_main() {
    [[ $(git branch --show-current) == main ]] || die "Check out main to publish locally."
    [[ -z $(git status --porcelain) ]] || die "Commit your changes before publishing."
}

publish() {
    local state expected uploaded
    [[ $(gh api "repos/$repo/commits/$tag" --jq .sha) == "$(git rev-parse HEAD)" ]] || die "Remote $tag does not point to this commit."
    swift Scripts/verify-update.swift "$out" "$version" "$key"
    (cd "$out" && shasum -a 256 "$archive" appcast.xml) | cmp - "$out/SHA256SUMS.txt"
    state=$(release_state)
    if [[ $state == new ]]; then
        gh release create "$tag" --repo "$repo" --verify-tag --draft --title "Connection Browser $version" \
            --notes "Requires a Mac with Apple silicon running macOS 26 or later. Download $archive from Assets, unzip it, and drag ConnectionBrowser.app into Applications."
    fi
    [[ $(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft) == true ]] || die "Only a draft may be updated."
    gh release upload "$tag" --repo "$repo" --clobber "$out/$archive" "$out/appcast.xml" "$out/SHA256SUMS.txt"
    expected=$(cd "$out" && shasum -a 256 "$archive" appcast.xml SHA256SUMS.txt | LC_ALL=C sort)
    uploaded=$(gh release view "$tag" --repo "$repo" --json assets \
        --jq '.assets[] | (.digest | sub("^sha256:"; "")) + "  " + .name' | LC_ALL=C sort)
    [[ $expected == "$uploaded" ]] || die "Draft assets do not match the signed build."
    [[ $(release_state) == draft ]] || die "Release state changed during the upload."
    gh release edit "$tag" --repo "$repo" --draft=false --latest
    verify_public
}

case "$mode" in
    prepare) prepare ;;
    verify) verify_public ;;
    check-version) release_state >/dev/null ;;
    publish-ci) publish ;;
    local)
        clean_main
        case "$(git remote get-url --push origin)" in
            "https://github.com/$repo"|"https://github.com/$repo.git"|"git@github.com:$repo.git"|"ssh://git@github.com/$repo.git") ;;
            *) die "origin must point to $repo." ;;
        esac
        release_state >/dev/null
        head=$(git rev-parse HEAD)
        git fetch --quiet --no-tags origin refs/heads/main
        git merge-base --is-ancestor FETCH_HEAD "$head" || die "Update main from origin before publishing."
        # A retry can reuse our own tag, but must never move an existing version.
        remote_tag=$(git ls-remote --refs origin "refs/tags/$tag")
        if git show-ref --verify --quiet "refs/tags/$tag"; then
            [[ $(git cat-file -t "refs/tags/$tag") == tag &&
               $(git rev-parse "refs/tags/$tag^{commit}") == "$head" &&
               $(git for-each-ref --format='%(contents:subject)' "refs/tags/$tag") == "$local_marker" ]] || die "Tag $tag already exists for a different release."
            [[ -z $remote_tag || ${remote_tag%%[[:space:]]*} == "$(git rev-parse "refs/tags/$tag")" ]] || die "Remote $tag differs."
        else
            [[ -z $remote_tag ]] || die "Tag $tag already exists on origin."
        fi
        prepare
        clean_main
        [[ $(git rev-parse HEAD) == "$head" ]] || die "HEAD changed during the build."
        if ! git show-ref --verify --quiet "refs/tags/$tag"; then git tag -a "$tag" "$head" -m "$local_marker"; fi
        git push --atomic origin "$head:refs/heads/main" "refs/tags/$tag"
        publish
        ;;
    *) die "Unknown release command: $mode" ;;
esac
