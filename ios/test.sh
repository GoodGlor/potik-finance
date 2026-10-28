#!/usr/bin/env bash
# Run the iOS suite, then take the test runner back off the simulator.
#
# xcodebuild installs MonitorFinanceUITests-Runner.app next to the real app
# so XCUITest has a second process to drive it from, and never cleans it up.
# It shows on the home screen as a second, near-identically named icon and
# does nothing when tapped, which is confusing enough to be worth this file.
#
#   ios/test.sh                                  # everything
#   ios/test.sh -only-testing:MonitorFinanceTests   # unit only, ~20 s
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SIM="${SIM:-iPhone 17 Pro}"   # NOT plain "iPhone 17" — a different device
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# PrivatFileImportTests picks a real .xlsx out of the Files app, which means
# the file has to be on the device before the suite starts — see the script.
SIM="$SIM" "$ROOT/ios/seed-privat-statement.sh" || \
  echo "test.sh: could not seed the statement — PrivatFileImportTests will fail" >&2

status=0
xcodebuild test \
  -project "$ROOT/ios/MonitorFinance.xcodeproj" \
  -scheme MonitorFinance \
  -destination "platform=iOS Simulator,name=$SIM" \
  "$@" || status=$?

# Always tidy up, pass or fail — a red suite is no reason to leave litter.
# Absolute path, not `xcrun simctl`: xcrun resolves utilities through the
# *active* developer directory, which is not necessarily the one exported
# above, and it then prints `unable to find utility "simctl"` into an
# otherwise clean run. The binary's location is stable under DEVELOPER_DIR.
SIMCTL="$DEVELOPER_DIR/usr/bin/simctl"
if [ -x "$SIMCTL" ]; then
  "$SIMCTL" uninstall "$SIM" ua.monitorfinance.uitests.xctrunner 2>/dev/null || true
else
  xcrun simctl uninstall "$SIM" ua.monitorfinance.uitests.xctrunner 2>/dev/null || true
fi

exit "$status"
