#!/usr/bin/env bash
# Put a real .xlsx statement into the simulator's Files app, under
# «On My iPhone», so PrivatFileImportTests can pick it the way a person does.
#
# The real import path is `.fileImporter` → UIDocumentPickerViewController.
# That picker renders its file browser in a remote view whose contents are
# NOT published to XCUITest, so a test cannot conjure a file into it — the
# file has to already exist on the device. This script is that setup step;
# ios/test.sh runs it before the suite.
#
# The bytes are the same invented statement the unit tests use, decoded out
# of PrivatStatementStub.swift so there is exactly one fixture in the repo
# and no second copy to drift.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SIM="${SIM:-iPhone 17 Pro}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMCTL="$DEVELOPER_DIR/usr/bin/simctl"

UDID="$("$SIMCTL" list devices available -j \
  | python3 -c "import json,sys
d=json.load(sys.stdin)['devices']
print(next(x['udid'] for v in d.values() for x in v if x['name']=='$SIM'))")"

# «On My iPhone» is the Files app's own local storage, an app group container.
# Its directory name is a fresh UUID per simulator, so find it by identifier.
DATA="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers/Shared/AppGroup"
GROUP=""
for g in "$DATA"/*/; do
  id="$(plutil -extract MCMMetadataIdentifier raw "$g/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null || true)"
  if [ "$id" = "group.com.apple.FileProvider.LocalStorage" ]; then GROUP="$g"; break; fi
done
if [ -z "$GROUP" ]; then
  echo "seed-privat-statement: no local Files storage on $SIM — boot it once first" >&2
  exit 1
fi

DEST="$GROUP/File Provider Storage/privat-statement.xlsx"
sed -n 's/.*private static let base64 = "\(.*\)"/\1/p' \
    "$ROOT/ios/MonitorFinance/Import/PrivatStatementStub.swift" \
  | tr -d '\n' | base64 -d > "$DEST"

echo "seed-privat-statement: $(wc -c < "$DEST" | tr -d ' ') bytes → On My iPhone/privat-statement.xlsx"
