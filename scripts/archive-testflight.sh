#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

scheme=BiteLens
configuration=Release
archive_options=(-quiet)
if [[ ${1:-} == --beta ]]; then
    scheme="BiteLens Beta"
    configuration="Beta Release"
    if [[ -n "${BITELENS_BETA_SUPPORT_EMAIL:-}" ]]; then
        archive_options+=("BITELENS_BETA_SUPPORT_EMAIL=$BITELENS_BETA_SUPPORT_EMAIL")
    fi
    shift
fi
tag=${1:-}
build=${2:-}
team=${3:-}

fail() {
    echo "$*" >&2
    exit 1
}

[[ $# == 3 && "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]{0,3}$ && "$team" =~ ^[A-Z0-9]{10}$ ]] ||
    fail "Usage: $0 [--beta] v0.1.0 BUILD_NUMBER APPLE_TEAM_ID"

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
remote="https://github.com/$repo.git"
release=$(gh release view "$tag" --repo "$repo" --json isDraft,isImmutable,isPrerelease,tagName \
    --jq 'select(.isDraft == false and .isImmutable and .isPrerelease) | .tagName')
[[ "$release" == "$tag" ]] || fail "Publish an immutable GitHub prerelease before archiving."

# Fetch the exact immutable tag from GitHub, bypassing any local tag with the same name.
git fetch --no-tags "$remote" "refs/tags/$tag"
commit=$(git rev-parse 'FETCH_HEAD^{commit}')
status=$(gh api "repos/$repo/compare/$commit...main" --jq .status)
[[ "$status" == ahead || "$status" == identical ]] ||
    fail "The released commit must be on main."

result=$(gh run list --repo "$repo" --workflow ci.yml --event release --commit "$commit" \
    --limit 1 --json conclusion --jq '.[0].conclusion // empty')
[[ "$result" == success ]] || fail "The release-triggered CI run for this commit must succeed."

# Keep the archive and build intermediates out of Git and compile only the released tree.
umask 077
output=$(mktemp -d "${TMPDIR:-/tmp}/bitelens-testflight.XXXXXXXX")
mkdir "$output/source"
git archive "$commit" | tar -xf - -C "$output/source"
if [[ -f App/Config/Local.xcconfig ]]; then
    cp App/Config/Local.xcconfig "$output/source/App/Config/Local.xcconfig"
fi
cd "$output/source"
scripts/check-release-version.sh "$tag"

archive="$output/BiteLens.xcarchive"
xcodebuild -project BiteLens.xcodeproj -scheme "$scheme" \
    -configuration "$configuration" -destination 'generic/platform=iOS' \
    -derivedDataPath "$output/build" -archivePath "$archive" \
    DEVELOPMENT_TEAM="$team" CURRENT_PROJECT_VERSION="$build" -allowProvisioningUpdates \
    "${archive_options[@]}" archive

app="$archive/Products/Applications/BiteLens.app"
codesign --verify --deep --strict "$app"
printf 'Verified %s archive for %s (%s), commit %s.\n%s\n' "$scheme" "$tag" "$build" "$commit" "$archive"
