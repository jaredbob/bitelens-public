#!/bin/bash
set -euo pipefail
selected_developer_dir="$(xcode-select -p)"
printf 'Selected developer tools: %s\n' "$selected_developer_dir"
if [[ "$selected_developer_dir" == */CommandLineTools ]]; then
    printf '%s\n' 'Full Xcode is required. Install/select a release supporting the target iPhone OS, then rerun.' >&2
    exit 1
fi
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
xcrun --sdk iphoneos --show-sdk-version
printf '%s\n' 'Toolchain available. Device OS compatibility, paid-team signing, and installation still need verification in Xcode.'
