#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
    echo "$*" >&2
    exit 1
}

tag=${1:-}
commit=${2:-}
[[ $# == 2 && "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$commit" =~ ^[0-9a-f]{40}$ ]] ||
    fail "Usage: $0 v0.5.0 FULL_COMMIT_SHA"

repo=jaredbob/bitelens-public
api="repos/$repo"
main=$(gh api --hostname github.com "$api/branches/main" --jq 'select(.protected == true) | .commit.sha') ||
    fail "Could not read main from $repo."
[[ "$main" =~ ^[0-9a-f]{40}$ ]] || fail "The main branch of $repo must be protected."

status=$(gh api --hostname github.com "$api/compare/$commit...$main" --jq .status) ||
    fail "Could not verify that $commit is on protected main."
[[ "$status" == ahead || "$status" == identical ]] ||
    fail "$commit is not on protected main (tip $main)."

run=$(gh api --hostname github.com --method GET "$api/actions/workflows/ci.yml/runs" \
    -f branch=main -f event=push -f head_sha="$commit" -f per_page=100 \
    --jq '.workflow_runs | max_by(.id) | select(.status == "completed" and .conclusion == "success") | .id') ||
    fail "Could not read BiteLens CI runs for $commit."
[[ "$run" =~ ^[0-9]+$ ]] ||
    fail "The latest BiteLens CI run for the push to main at $commit must have completed successfully."

gh api --hostname github.com "$api/contents/BiteLens.xcodeproj/project.pbxproj?ref=$commit" \
    -H 'Accept: application/vnd.github.raw+json' |
    scripts/check-release-version.sh "$tag" /dev/stdin

# GitHub uses the existing tag's commit when a release reuses that tag.
existing=$(gh api --hostname github.com "$api/git/matching-refs/tags/$tag" \
    --jq ".[] | select(.ref == \"refs/tags/$tag\") | .ref") ||
    fail "Could not look up $tag in $repo."
if [[ -n "$existing" ]]; then
    tagged_commit=$(gh api --hostname github.com "$api/commits/tags/$tag" --jq .sha) ||
        fail "Could not resolve $tag to a commit."
    [[ "$tagged_commit" == "$commit" ]] || fail "$tag already points to $tagged_commit."
fi

printf 'Release check passed for %s at %s.\nCI: https://github.com/%s/actions/runs/%s\n' "$tag" "$commit" "$repo" "$run"
