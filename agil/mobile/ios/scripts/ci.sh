# Build + test the AgilCallsSDK package on macOS.
#
#   cd agil/mobile/ios
#   bash scripts/ci.sh
#
# Optional environment:
#   SCHEME=AgilCallsSDK-Package  (if Xcode exposes the package scheme with a suffix)
#   SIMULATOR="iPhone 16"        (default: iPhone 15)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="${SCHEME:-AgilCallsSDK}"
SIMULATOR="${SIMULATOR:-iPhone 15}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.build/DerivedData}"

echo "== Toolchain =="
xcodebuild -version
swift --version

echo "== Manifest =="
swift package describe
swift package dump-package >/dev/null

echo "== Schemes =="
xcodebuild -list -json

echo "== Build (device SDK, no signing) =="
xcodebuild \
  -scheme "$SCHEME" \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "== Unit tests (simulator) =="
xcodebuild \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$SIMULATOR" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  test

echo "== OK =="
