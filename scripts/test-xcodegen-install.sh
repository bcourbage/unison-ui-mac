#!/usr/bin/env bash
# Regression for fail-closed XcodeGen installation.
#
# A repository-local install whose binary reports the pinned version but whose
# SettingPresets are missing still runs, yet silently emits a materially
# different project.pbxproj. This proves such an incomplete install is:
#   1. rejected by `install-xcodegen.sh --verify`;
#   2. repaired by `make generate` BEFORE xcodegen is invoked (and the generated
#      plist is correct afterward).
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"   # repo root
MAKE="${MAKE:-make}"
bin="$(scripts/install-xcodegen.sh --print-bin)"
dest="$(dirname "$(dirname "$bin")")"

echo "[1] ensure a complete install, then confirm --verify accepts it"
scripts/install-xcodegen.sh >/dev/null
scripts/install-xcodegen.sh --verify >/dev/null \
  || { echo "FAIL: a freshly installed XcodeGen did not pass --verify"; exit 1; }

# Remove ONE consumed preset that a hand-enumerated allowlist could miss (this
# one changes the test target's runpaths). The full-tree digest must still catch
# it — that is the point of validating the whole tree, not a curated list.
victim="$dest/share/xcodegen/SettingPresets/Product_Platform/bundle.unit-test_macOS.yml"
echo "[2] corrupt it: remove a single consumed preset, keep the valid-version binary"
[ -f "$victim" ] || { echo "FAIL: expected preset not present to begin with: $victim"; exit 1; }
rm -f "$victim"
[ -x "$bin" ] && [ "$("$bin" --version | awk '{print $2}')" = "$(scripts/install-xcodegen.sh --print-version)" ] \
  || { echo "FAIL: the binary should still exist and report the pinned version"; exit 1; }
if scripts/install-xcodegen.sh --verify >/dev/null 2>&1; then
  echo "FAIL: --verify accepted an install with a single missing preset"; exit 1
fi
echo "  ok: --verify rejects the install with one missing preset"

echo "[3] make generate must repair the install before generating"
"$MAKE" generate >/dev/null
scripts/install-xcodegen.sh --verify >/dev/null \
  || { echo "FAIL: install still incomplete after make generate"; exit 1; }
test -f "$victim" \
  || { echo "FAIL: the missing preset was not restored"; exit 1; }
scripts/verify-plist-keys.sh --generated Resources/Info.plist >/dev/null \
  || { echo "FAIL: generated plist is wrong after repair"; exit 1; }

echo "PASS: an incomplete XcodeGen install (one missing preset) is detected and repaired before generation"
