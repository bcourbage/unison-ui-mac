#!/usr/bin/env bash
# INDEPENDENT security-policy assertions on the generated plist / built app.
#
# Unlike scripts/verify-plist-keys.sh — which proves project.yml → plist
# PROPAGATION by reading its expectations FROM project.yml — this script hard-
# codes the security-critical values. If project.yml is weakened (e.g.
# `SURequireSignedFeed: false`, a non-production SUFeedURL, or the failure-
# expiration relaxed), the generated plist changes and THIS check FAILS. The two
# scripts are complementary layers: propagation (verify-plist-keys.sh) + policy
# (this). Changing any constant below is a deliberate, reviewed security decision.
#
# The release's own signing/appcast canaries continue to prove that the EdDSA
# public key here matches the key the feed is actually signed with; this only
# asserts the key's shape and that signed-feed enforcement is on.
#
#   --generated <plist>   literal Sparkle keys present in the generated plist
#   --app <app.app>       the above + resolved bundle id and macOS floor
set -euo pipefail

# ---- Policy constants (change only via reviewed security decision) ----------
POLICY_FEED_URL="https://updates.courbage.net/unison-ui-mac/appcast.xml"
POLICY_BUNDLE_ID="net.courbage.unison-ui-mac"
POLICY_MIN_MACOS="15.0"
# Ed25519 public key = 32 bytes → 43 Base64 chars + one '=' pad (44 total).
POLICY_EDKEY_RE='^[A-Za-z0-9+/]{43}=$'

usage() { echo "usage: $0 --generated <plist> | --app <app.app>" >&2; exit 2; }
[ $# -eq 2 ] || usage
mode="$1"; target="$2"

case "$mode" in
  --generated) plist="$target" ;;
  --app)       plist="$target/Contents/Info.plist" ;;
  *) usage ;;
esac
[ -f "$plist" ] || { echo "error: no Info.plist at $plist" >&2; exit 1; }

fail=0
pget() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null; }
eq() {   # key expected
  local got; got="$(pget "$1" || true)"
  if [ "$got" = "$2" ]; then echo "ok    $1 = $got"; else echo "FAIL  $1: '$got' != policy '$2'"; fail=1; fi
}

echo "== policy assertions ($mode $target) =="

eq SUFeedURL "$POLICY_FEED_URL"
eq SURequireSignedFeed true
eq SUVerifyUpdateBeforeExtraction true
eq SUSignedFeedFailureExpirationInterval 0

edkey="$(pget SUPublicEDKey || true)"
if printf '%s' "$edkey" | grep -Eq "$POLICY_EDKEY_RE"; then
  echo "ok    SUPublicEDKey has the 32-byte Base64 shape"
else
  echo "FAIL  SUPublicEDKey '$edkey' is not a 32-byte Base64 ed25519 key"; fail=1
fi

if [ "$mode" = "--app" ]; then
  eq CFBundleIdentifier "$POLICY_BUNDLE_ID"
  eq LSMinimumSystemVersion "$POLICY_MIN_MACOS"
fi

if [ "$fail" -ne 0 ]; then
  echo "== policy verification FAILED ==" >&2
  exit 1
fi
echo "== policy verification passed =="
