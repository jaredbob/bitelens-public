#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

tag=${1:-}
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Use a release tag such as v0.1.0." >&2
    exit 1
fi
if ! awk -v version="${tag#v};" '
    $1 == "MARKETING_VERSION" {
        count++
        if ($3 != version) mismatch = 1
    }
    END { exit (count == 0 || mismatch) }
' "${2:-BiteLens.xcodeproj/project.pbxproj}"; then
    echo "The tag must match MARKETING_VERSION for every Xcode target." >&2
    exit 1
fi
