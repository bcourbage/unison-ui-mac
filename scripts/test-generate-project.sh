#!/usr/bin/env bash
# Generation-contract regression test.
#
# Proves the supported generation step (`make generate`) is DETERMINISTIC:
#   1. with the generated plist absent, generation creates it;
#   2. the created plist matches project.yml;
#   3. a deliberately-placed STALE plist at the generated path is REPLACED by
#      the next generation (an old ignored local copy can never survive as
#      build input).
#
# Run via `make check-generate-contract` so the Makefile supplies the variables
# xcodegen needs. Requires the pinned XcodeGen (the generation step enforces it).
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"   # repo root
MAKE="${MAKE:-make}"
plist="Resources/Info.plist"

echo "[1] start with the generated plist absent"
rm -f "$plist"
[ ! -f "$plist" ] || { echo "FAIL: could not remove $plist"; exit 1; }

echo "[2] generate — the plist must appear and match project.yml"
"$MAKE" generate >/dev/null
[ -f "$plist" ] || { echo "FAIL: generation did not create $plist"; exit 1; }
scripts/verify-plist-keys.sh --generated "$plist" >/dev/null \
  || { echo "FAIL: freshly generated plist does not match project.yml"; exit 1; }

echo "[3] place a STALE plist at the generated path"
cat > "$plist" <<'STALE'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>SUFeedURL</key><string>https://stale.invalid/appcast.xml</string>
  <key>SUPublicEDKey</key><string>STALEKEYSTALEKEYSTALEKEYSTALEKEYSTALEKEYSTA=</string>
  <key>SURequireSignedFeed</key><false/>
  <key>SUVerifyUpdateBeforeExtraction</key><false/>
  <key>SUSignedFeedFailureExpirationInterval</key><integer>1728000</integer>
</dict></plist>
STALE
grep -q 'stale.invalid' "$plist" || { echo "FAIL: could not stage the stale plist"; exit 1; }

echo "[4] regenerate over the stale plist"
"$MAKE" generate >/dev/null

echo "[5] prove the stale values were replaced with project.yml values"
if grep -q 'stale.invalid' "$plist"; then
  echo "FAIL: stale SUFeedURL survived regeneration — generation is NOT deterministic"
  exit 1
fi
scripts/verify-plist-keys.sh --generated "$plist" \
  || { echo "FAIL: regenerated plist does not match project.yml"; exit 1; }

echo "[6] a different xcodegen earlier on PATH must NOT be used (repository-pinned wins)"
shadow="$(mktemp -d)"
cat > "$shadow/xcodegen" <<'FAKE'
#!/bin/sh
echo "FAKE PATH xcodegen was invoked — the pinned repo-local copy should have been used" >&2
exit 87
FAKE
chmod +x "$shadow/xcodegen"
if ! PATH="$shadow:$PATH" "$MAKE" generate >/dev/null; then
  echo "FAIL: generation used the PATH xcodegen instead of the repository-pinned binary"
  rm -rf "$shadow"; exit 1
fi
rm -rf "$shadow"
scripts/verify-plist-keys.sh --generated "$plist" >/dev/null \
  || { echo "FAIL: plist wrong after PATH-shadow regeneration"; exit 1; }
echo "  ok: generation ignored the PATH xcodegen and used the repository-pinned copy"

echo "PASS: generation is deterministic (absent created, stale replaced) and always uses the repository-pinned XcodeGen"
