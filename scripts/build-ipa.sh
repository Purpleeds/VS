#!/usr/bin/env bash
# Release IPA build. Run from WSL.
#   1. swift test
#   2. bump CFBundleVersion
#   3. xtool dev build --ipa -c release   (any error OR warning fails the script)
#   4. copy the .ipa to the Windows Desktop (overwrite)
# Override the destination with PITCHLANE_IPA_DEST if needed.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${PITCHLANE_IPA_DEST:-/mnt/c/Users/Purpl/Desktop/PitchLane.ipa}"
LOG="build.log"

echo "== swift test =="
swift test

build=$(scripts/bump-build.sh)
echo "== building build number $build (release) =="

set +e
xtool dev build --ipa -c release 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  echo "build-ipa: xtool failed (exit $status); see $LOG" >&2
  exit "$status"
fi
if grep -Eiq '(^|[^a-z])(warning|error):' "$LOG"; then
  echo "build-ipa: build produced warnings/errors; fix ALL of them:" >&2
  grep -Ei '(^|[^a-z])(warning|error):' "$LOG" >&2
  exit 1
fi

ipa=$(find xtool -maxdepth 2 -name '*.ipa' -print -quit 2>/dev/null || true)
if [[ -z "$ipa" ]]; then
  echo "build-ipa: no .ipa found under xtool/" >&2
  exit 1
fi
if [[ ! -d "$(dirname "$DEST")" ]]; then
  echo "build-ipa: destination folder $(dirname "$DEST") does not exist" >&2
  exit 1
fi
cp -f "$ipa" "$DEST"
echo "== done: build $build -> $DEST =="
