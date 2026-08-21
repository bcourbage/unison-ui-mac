#!/bin/sh
# test-sign-app.sh — regression tests for sign-app.sh's fail-fast guards.
#
# Exercises the guards that fire BEFORE any codesign call, using a fake bundle
# skeleton (empty component stand-ins) so no real Sparkle framework or signing
# identity is needed — it runs on a bare CI runner. The signing happy-path and
# the reject-unexpected-embedded-code rule need a real built + signed bundle and
# are covered by the release pipeline, not here.
set -u

here=$(cd "$(dirname "$0")" && pwd)
signer="$here/sign-app.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# Build a fake bundle with every required Sparkle component present.
skel() {
	d="$tmp/$1"; rm -rf "$d"
	v="$d/Contents/Frameworks/Sparkle.framework/Versions/Current"
	mkdir -p "$v/XPCServices/Downloader.xpc" "$v/XPCServices/Installer.xpc" "$v/Updater.app" "$d/Contents/MacOS"
	: > "$v/Autoupdate"; : > "$d/Contents/MacOS/unison-ui-mac"
	printf '%s' "$d"
}

# expect_fail <desc> <app> <identity|""> <needle>
expect_fail() {
	desc="$1"; app="$2"; id="$3"; needle="$4"
	if [ -n "$id" ]; then "$signer" "$app" "$id" >/dev/null 2>"$tmp/err"; else "$signer" "$app" >/dev/null 2>"$tmp/err"; fi
	rc=$?
	if [ "$rc" -ne 0 ] && grep -q "$needle" "$tmp/err"; then r=PASS; else r=FAIL; fail=1; fi
	printf '  %-22s rc=%s  %s\n' "$desc" "$rc" "$r"
}

echo "sign-app.sh guards:"

a=$(skel a.app); rm -rf "$a/Contents/Frameworks/Sparkle.framework"
expect_fail "missing-framework" "$a" "-" "required Sparkle.framework not found"

b=$(skel b.app); rm -rf "$b/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc"
expect_fail "missing-component" "$b" "-" "required Sparkle component missing"

c=$(skel c.app)
expect_fail "non-devid-identity" "$c" "Apple Development: nobody (ZZZZZZZZZZ)" "is not a Developer ID Application identity"

if [ "$fail" -ne 0 ]; then echo "SIGN-APP GUARD TESTS FAILED" >&2; exit 1; fi
echo "all sign-app guard tests passed"
