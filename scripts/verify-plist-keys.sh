#!/usr/bin/env bash
# Fail-closed verifier for the critical Info.plist values, checked against the
# expectations declared in project.yml (the single source of truth — no
# duplicated literals here).
#
# Two modes:
#   --generated <plist>   Verify the xcodegen-generated Resources/Info.plist.
#                         Only the keys that carry LITERAL values there are
#                         checked (the Sparkle security keys); bundle id /
#                         executable / version / min-os are $(...) build-setting
#                         references that xcodebuild resolves, so they are
#                         verified in --app mode instead.
#   --app <app>           Verify the BUILT (and, on the release path, signed +
#                         stapled) application bundle — the bytes that ship. All
#                         keys, including the resolved bundle id, executable
#                         (which must name an existing Mach-O), min-os, marketing
#                         version, and build number.
#
# Exit 0 iff every checked value matches project.yml; any missing/mismatched
# value fails the run with a specific message.
set -euo pipefail

usage() { echo "usage: $0 --generated <plist> | --app <app.app>" >&2; exit 2; }
[ $# -eq 2 ] || usage
mode="$1"; target="$2"

root="$(cd "$(dirname "$0")/.." && pwd)"
projyml="$root/project.yml"
[ -f "$projyml" ] || { echo "error: project.yml not found at $projyml" >&2; exit 1; }

# --- expected values, extracted from project.yml -----------------------------
# Each key appears once; take the text after the first colon, trimmed of quotes
# and whitespace. Fail closed if the authority itself is missing a key.
yml_val() {
  local key="$1" v
  v="$(grep -E "^[[:space:]]*${key}:[[:space:]]" "$projyml" | head -1 \
        | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^\"//; s/\"$//; s/[[:space:]]*$//")"
  [ -n "$v" ] || { echo "error: project.yml has no value for '$key' (authority incomplete)" >&2; exit 1; }
  printf '%s' "$v"
}
# deploymentTarget is nested (deploymentTarget: / macOS: x); read the macOS line.
yml_deploy_macos() {
  awk '/deploymentTarget:/{f=1} f&&/macOS:/{gsub(/[",]/,""); n=split($0,a,":"); gsub(/[[:space:]]/,"",a[n]); print a[n]; exit}' "$projyml"
}

exp_feed="$(yml_val SUFeedURL)"
exp_edkey="$(yml_val SUPublicEDKey)"
exp_reqsigned="$(yml_val SURequireSignedFeed)"
exp_verifybefore="$(yml_val SUVerifyUpdateBeforeExtraction)"
exp_failexpiry="$(yml_val SUSignedFeedFailureExpirationInterval)"
exp_bundleid="$(yml_val PRODUCT_BUNDLE_IDENTIFIER)"
exp_exec="$(yml_val PRODUCT_NAME)"
exp_marketing="$(yml_val MARKETING_VERSION)"
exp_build="$(yml_val CURRENT_PROJECT_VERSION)"
exp_minos="$(yml_deploy_macos)"

# --- plist reader ------------------------------------------------------------
case "$mode" in
  --generated) plist="$target" ;;
  --app)       plist="$target/Contents/Info.plist" ;;
  *) usage ;;
esac
[ -f "$plist" ] || { echo "error: no Info.plist at $plist" >&2; exit 1; }

fail=0
pget() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null; }
check() {
  local key="$1" want="$2" got
  got="$(pget "$key" || true)"
  if [ -z "$got" ]; then echo "FAIL  $key: absent (want '$want')"; fail=1; return; fi
  if [ "$got" != "$want" ]; then echo "FAIL  $key: '$got' != expected '$want'"; fail=1; return; fi
  echo "ok    $key = $got"
}

echo "== verifying $mode $target against project.yml =="

# Sparkle security keys — literal in both the generated plist and the built app.
check SUFeedURL "$exp_feed"
check SUPublicEDKey "$exp_edkey"
check SURequireSignedFeed "$exp_reqsigned"
check SUVerifyUpdateBeforeExtraction "$exp_verifybefore"
check SUSignedFeedFailureExpirationInterval "$exp_failexpiry"

if [ "$mode" = "--app" ]; then
  check CFBundleIdentifier "$exp_bundleid"
  check CFBundleExecutable "$exp_exec"
  check CFBundleShortVersionString "$exp_marketing"
  check CFBundleVersion "$exp_build"
  check LSMinimumSystemVersion "$exp_minos"

  # The named main executable must exist and be a regular file (a plausibly real
  # bundle, not just a matching string).
  exe="$(pget CFBundleExecutable || true)"
  if [ -n "$exe" ] && [ ! -f "$target/Contents/MacOS/$exe" ]; then
    echo "FAIL  CFBundleExecutable names '$exe' but $target/Contents/MacOS/$exe is missing"
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "== plist verification FAILED ==" >&2
  exit 1
fi
echo "== plist verification passed =="
