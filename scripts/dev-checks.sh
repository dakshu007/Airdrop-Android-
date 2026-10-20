#!/usr/bin/env bash
# Fast local checks that do not need the Android SDK or Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Kotlin protocol core"
android/android/gradlew -p android/core test installDist --no-daemon -q

echo "== Kotlin CLI round trip"
CLI="$PWD/android/core/build/install/crossdrop-cli/bin/crossdrop-cli"
LC_ALL=C.UTF-8 integration-tests/interop.sh "$CLI" "$CLI"

echo "== React Native UI"
(cd android && npm run typecheck && npm run lint && npm test -- --ci)

if command -v swift >/dev/null 2>&1 && [[ "$(uname)" == "Darwin" ]]; then
  echo "== Swift core"
  (cd macos && swift test)
fi
echo "All checks passed."
