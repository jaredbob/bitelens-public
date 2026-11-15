#!/bin/bash
# Run the BiteLens UI smoke suite on an available iPhone simulator.
# The script does not read App/Config/Local.xcconfig. Simulator builds skip
# signing and use an empty entitlements file so HealthKit and the App Group
# do not require a development team. Release builds are unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null 2>&1 || ! command -v xcrun >/dev/null 2>&1; then
  echo "UI smoke tests need a full Xcode with an iOS Simulator runtime." >&2
  exit 1
fi

selection="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
data = json.load(sys.stdin)
found = []
for runtime, devices in data.get("devices", {}).items():
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?", runtime)
    if not match:
        continue
    version = tuple(int(part) for part in match.groups() if part is not None)
    for device in devices:
        name = device.get("name", "")
        if device.get("isAvailable") and name.startswith("iPhone"):
            found.append((version, name, device["udid"]))

def score(name):
    lowered = name.lower()
    if "se" in lowered or "mini" in lowered:
        return 0
    if "pro max" in lowered or "plus" in lowered:
        return 1
    if "pro" in lowered:
        return 2
    return 3

if not found:
    sys.exit("No available iPhone simulator. Install an iOS Simulator runtime in Xcode.")
version, name, udid = max(found, key=lambda item: (item[0], score(item[1]), item[1]))
print("%s\t%s\t%s" % (udid, name, ".".join(str(part) for part in version)))
')"
udid="${selection%%$'\t'*}"
echo "UI smoke destination: ${selection#*$'\t'} ($udid)"

entitlements="$(mktemp -d)/Empty.entitlements"
cat >"$entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
EOF

derived="${RUNNER_TEMP:-/tmp}/bitelens-ui-tests"
rm -rf "$derived"
test_selection=BiteLensUITests
if [[ ${1:-} == --beta ]]; then
  scheme="BiteLens Beta"
  test_selection=BiteLensUITests/CaptureSmokeTests/testLaunchWithoutUITestModeShowsSignIn
else
  scheme="$(xcodebuild -list -json -project BiteLens.xcodeproj | python3 -c '
import json, sys
schemes = json.load(sys.stdin)["project"]["schemes"]
project_scheme = "BiteLens (BiteLens project)"
print(project_scheme if project_scheme in schemes else "BiteLens")
')"
fi
xcodebuild test \
  -project BiteLens.xcodeproj \
  -scheme "$scheme" \
  -destination "platform=iOS Simulator,id=$udid" \
  -only-testing:"$test_selection" \
  -derivedDataPath "$derived" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  BITELENS_PERSONAL_SUPABASE_HOST=example.invalid \
  BITELENS_PERSONAL_SUPABASE_PUBLISHABLE_KEY=sb_publishable_test \
  BITELENS_OWNER_ID=00000000-0000-4000-8000-000000000001 \
  BITELENS_BETA_SUPABASE_HOST=example.invalid \
  BITELENS_BETA_SUPABASE_PUBLISHABLE_KEY=sb_publishable_test \
  "CODE_SIGN_ENTITLEMENTS=$entitlements" \
  COMPILER_INDEX_STORE_ENABLE=NO
