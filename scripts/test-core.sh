#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Swift 6.4's CLT-only SwiftBuild runner can omit TestingMacros on incremental
# builds. Native SwiftPM needs the bundled Testing framework made explicit.
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == */CommandLineTools ]]; then
    swift test --build-system native \
      -Xswiftc -F -Xswiftc "$developer_dir/Library/Developer/Frameworks" \
      -Xswiftc -load-plugin-library \
      -Xswiftc "$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
      -Xlinker "-F$developer_dir/Library/Developer/Frameworks" \
      -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/Frameworks" "$@"
else
    swift test "$@"
fi
