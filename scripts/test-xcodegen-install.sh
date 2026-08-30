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

echo "[2] corrupt it: remove share/ (presets) but keep the valid-version binary"
rm -rf "$dest/share"
[ -x "$bin" ] && [ "$("$bin" --version | awk '{print $2}')" = "$(scripts/install-xcodegen.sh --print-version)" ] \
  || { echo "FAIL: the binary should still exist and report the pinned version"; exit 1; }
if scripts/install-xcodegen.sh --verify >/dev/null 2>&1; then
  echo "FAIL: --verify accepted an install with missing presets"; exit 1
fi
echo "  ok: --verify rejects the incomplete install"

echo "[3] make generate must repair the install before generating"
"$MAKE" generate >/dev/null
scripts/install-xcodegen.sh --verify >/dev/null \
  || { echo "FAIL: install still incomplete after make generate"; exit 1; }
test -f "$dest/share/xcodegen/SettingPresets/base.yml" \
  || { echo "FAIL: presets were not restored"; exit 1; }
scripts/verify-plist-keys.sh --generated Resources/Info.plist >/dev/null \
  || { echo "FAIL: generated plist is wrong after repair"; exit 1; }

echo "PASS: an incomplete XcodeGen install is detected and repaired before generation"
