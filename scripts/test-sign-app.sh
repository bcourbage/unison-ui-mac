#!/bin/sh
# test-sign-app.sh — regression tests for sign-app.sh's fail-closed structural
# checks (identity resolution, required Sparkle components, and the embedded-
# code inventory). These all run BEFORE any codesign call, so they exercise on
# a bare runner with no signing identity, using a fake bundle skeleton plus a
# real Mach-O stub for the raw-helper case.
#
# NOT covered here: the actual signing happy-paths (ad-hoc and Developer ID),
# which need a real codesign-valid Sparkle bundle. The ad-hoc/Developer ID paths
# are exercised against a real built bundle during local release prep and by the
# release pipeline; they are not claimed to run in this standalone gate.
set -u

here=$(cd "$(dirname "$0")" && pwd)
signer="$here/sign-app.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# A real Mach-O executable for the raw-helper case (cc is present on the runner).
helper="$tmp/helper"
echo 'int main(void){return 0;}' | cc -x c -o "$helper" - 2>/dev/null || {
	echo "test-sign-app: cc unavailable; cannot build the Mach-O stub" >&2; exit 1; }

# Fake bundle with every required Sparkle component, a main executable, and an
# Info.plist naming it (the inventory reads CFBundleExecutable).
skel() {
	d="$tmp/$1"; rm -rf "$d"
	v="$d/Contents/Frameworks/Sparkle.framework/Versions/Current"
	mkdir -p "$v/XPCServices/Downloader.xpc" "$v/XPCServices/Installer.xpc" "$v/Updater.app" "$d/Contents/MacOS"
	: > "$v/Autoupdate"
	: > "$d/Contents/MacOS/unison-ui-mac"
	: > "$d/Contents/MacOS/cltool"
	cat > "$d/Contents/Info.plist" <<-PLIST
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0"><dict>
		<key>CFBundleExecutable</key><string>unison-ui-mac</string>
		</dict></plist>
	PLIST
	printf '%s' "$d"
}

# expect_fail <desc> <app> <identity|""> <needle>
expect_fail() {
	desc="$1"; app="$2"; id="$3"; needle="$4"
	if [ -n "$id" ]; then "$signer" "$app" "$id" >/dev/null 2>"$tmp/err"; else "$signer" "$app" >/dev/null 2>"$tmp/err"; fi
	rc=$?
	if [ "$rc" -ne 0 ] && grep -q "$needle" "$tmp/err"; then r=PASS; else r=FAIL; fail=1; fi
	printf '  %-26s rc=%s  %s\n' "$desc" "$rc" "$r"
}

echo "sign-app.sh structural checks:"

a=$(skel a.app); rm -rf "$a/Contents/Frameworks/Sparkle.framework"
expect_fail "missing-framework" "$a" "-" "required Sparkle.framework not found"

b=$(skel b.app); rm -rf "$b/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc"
expect_fail "missing-component" "$b" "-" "required Sparkle component missing"

c=$(skel c.app)
expect_fail "non-devid-identity" "$c" "Apple Development: nobody (ZZZZZZZZZZ)" "is not a Developer ID Application identity"

d=$(skel d.app); mkdir -p "$d/Contents/Helpers"; cp "$helper" "$d/Contents/Helpers/evil-helper"
expect_fail "raw-macho-helper" "$d" "-" "unexpected embedded code"

e=$(skel e.app); mkdir -p "$e/Contents/Frameworks/Other.framework"
expect_fail "unexpected-framework" "$e" "-" "unexpected embedded code"

# A failing classifier (`file`) must ABORT — not be read as "not Mach-O" and let
# a helper slip through. Shadow `file` with a stub that always fails.
g=$(skel g.app)
mkdir -p "$tmp/stub_file"; printf '#!/bin/sh\nexit 1\n' > "$tmp/stub_file/file"; chmod +x "$tmp/stub_file/file"
PATH="$tmp/stub_file:$PATH" "$signer" "$g" - >/dev/null 2>"$tmp/err"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "could not classify" "$tmp/err"; then r=PASS; else r=FAIL; fail=1; fi
printf '  %-26s rc=%s  %s\n' "classifier-failure" "$rc" "$r"

# A failing `sort` must ABORT — not yield an empty inventory that passes.
h=$(skel h.app)
mkdir -p "$tmp/stub_sort"; printf '#!/bin/sh\nexit 1\n' > "$tmp/stub_sort/sort"; chmod +x "$tmp/stub_sort/sort"
PATH="$tmp/stub_sort:$PATH" "$signer" "$h" - >/dev/null 2>"$tmp/err"; rc=$?
if [ "$rc" -ne 0 ]; then r=PASS; else r=FAIL; fail=1; fi
printf '  %-26s rc=%s  %s\n' "sort-failure" "$rc" "$r"

# The `unison` launcher is part of every shipped bundle: its absence must fail
# the structural stage, before any signing.
i=$(skel i.app); rm -f "$i/Contents/MacOS/cltool"
expect_fail "missing-cltool" "$i" "-" "required command-line launcher missing"

# A real Mach-O at Contents/MacOS/cltool is the whitelisted launcher, NOT
# unexpected embedded code. The run still fails later (the skeleton's Sparkle
# files are empty and cannot be signed), so assert only that the inventory did
# not reject it.
j=$(skel j.app); cp "$helper" "$j/Contents/MacOS/cltool"
"$signer" "$j" - >/dev/null 2>"$tmp/err"
if grep -q "unexpected embedded code" "$tmp/err"; then r=FAIL; fail=1; else r=PASS; fi
printf '  %-26s %s\n' "cltool-whitelisted" "$r"

if [ "$fail" -ne 0 ]; then echo "SIGN-APP TESTS FAILED" >&2; exit 1; fi
echo "all sign-app structural tests passed"
