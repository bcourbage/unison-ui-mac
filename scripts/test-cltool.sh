#!/bin/sh
# test-cltool.sh — tests for Sources/CLTool/cltool.c, the `unison` launcher.
#
# Compiles the tool against a throwaway bundle identifier, so the Launch Services
# fallback can never find a real installed app, into fake bundles whose main
# "executable" is a shell script that records how it was invoked and exits 7.
# No Xcode, no OCaml, no signing identity: cc and the system frameworks only.
set -u

here=$(cd "$(dirname "$0")" && pwd)
src="$here/../Sources/CLTool/cltool.c"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
test_id="net.courbage.unison-ui-mac.cltool-test.invalid"

tool="$tmp/cltool"
cc -Wall -Wextra -Werror \
	-DCLTOOL_BUNDLE_ID="\"$test_id\"" \
	-framework CoreFoundation -framework CoreServices \
	-o "$tool" "$src" \
	|| { echo "test-cltool: cannot compile $src" >&2; exit 1; }

# make_bundle <dir> <identifier|"">  — a bundle with the launcher inside; an
# empty identifier omits Info.plist altogether.
make_bundle() {
	d="$1"; id="$2"
	mkdir -p "$d/Contents/MacOS"
	cp "$tool" "$d/Contents/MacOS/cltool"
	cat > "$d/Contents/MacOS/unison-ui-mac" <<-'FAKE'
		#!/bin/sh
		printf 'argv0=%s\n' "$0"
		for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
		exit 7
	FAKE
	chmod +x "$d/Contents/MacOS/unison-ui-mac"
	[ -n "$id" ] && cat > "$d/Contents/Info.plist" <<-PLIST
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0"><dict>
		<key>CFBundleIdentifier</key><string>$id</string>
		<key>CFBundleExecutable</key><string>unison-ui-mac</string>
		<key>CFBundlePackageType</key><string>APPL</string>
		</dict></plist>
	PLIST
	return 0
}

check() {
	if [ "$2" -eq 0 ]; then r=PASS; else r=FAIL; fail=1; fi
	printf '  %-48s %s\n' "$1" "$r"
}

echo "cltool launcher:"

app="$tmp/Fake.app"; make_bundle "$app" "$test_id"
macos="$app/Contents/MacOS"
# The tool resolves its own path with realpath(3); compare against the same.
expected_exe="$(cd "$macos" && pwd -P)/unison-ui-mac"
mkdir -p "$tmp/bin"

# --- Reached through a symlink named `unison` (cask / manual install) ---------
ln -s "$macos/cltool" "$tmp/bin/unison"
out=$("$tmp/bin/unison" -ui text "my profile" -server 2>"$tmp/err"); rc=$?
[ "$rc" -eq 7 ]; check "symlink: exit status passes through" $?
expected="argv0=$expected_exe
arg=[-ui]
arg=[text]
arg=[my profile]
arg=[-server]"
[ "$out" = "$expected" ]; check "symlink: argv0 resolved, arguments intact" $?
[ ! -s "$tmp/err" ]; check "symlink: stderr silent on success" $?

# --- Invoked by its real path inside the bundle -------------------------------
out=$("$macos/cltool" -version 2>"$tmp/err"); rc=$?
[ "$rc" -eq 7 ] && [ "$out" = "argv0=$expected_exe
arg=[-version]" ]; check "direct: resolves via the bundle's Info.plist" $?

out=$("$macos/cltool" 2>"$tmp/err"); rc=$?
[ "$rc" -eq 7 ] && [ "$out" = "argv0=$expected_exe" ]; check "direct: no arguments" $?

# --- Copied out of the bundle: Launch Services finds no app, fails closed -----
cp "$tool" "$tmp/unison-copy"
out=$("$tmp/unison-copy" -version 2>"$tmp/err"); rc=$?
[ "$rc" -eq 1 ]; check "copied out: exit 1" $?
[ -z "$out" ]; check "copied out: nothing on stdout" $?
grep -q "registered with Launch Services" "$tmp/err" && grep -q "cannot locate" "$tmp/err"
check "copied out: stderr names the problem" $?

# --- Inside a bundle with a foreign identifier: refused, no fallback ---------
foreign="$tmp/Foreign.app"; make_bundle "$foreign" "edu.upenn.cis.Unison"
out=$("$foreign/Contents/MacOS/cltool" -version 2>"$tmp/err"); rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] && grep -q "bundle identifier edu.upenn.cis.Unison" "$tmp/err"
check "foreign bundle id: exit 1, names both identifiers" $?
! grep -q "Launch Services" "$tmp/err"; check "foreign bundle id: no Launch Services fallback" $?

# --- Inside a genuine bundle whose executable is missing: damaged, no fallback
damaged="$tmp/Damaged.app"; make_bundle "$damaged" "$test_id"; rm "$damaged/Contents/MacOS/unison-ui-mac"
ln -s "$damaged/Contents/MacOS/cltool" "$tmp/bin/unison-damaged"
out=$("$tmp/bin/unison-damaged" -version 2>"$tmp/err"); rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] && grep -q "damaged" "$tmp/err"
check "damaged bundle: exit 1, stdout empty, says damaged" $?
! grep -q "Launch Services" "$tmp/err"; check "damaged bundle: no Launch Services fallback" $?

# --- Inside a bundle layout with no Info.plist -------------------------------
noplist="$tmp/NoPlist.app"; make_bundle "$noplist" ""
out=$("$noplist/Contents/MacOS/cltool" 2>"$tmp/err"); rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ]; check "no Info.plist: exit 1, stdout empty" $?

# --- A non-executable sibling must not be exec'd ------------------------------
noexec="$tmp/NoExec.app"; make_bundle "$noexec" "$test_id"; chmod -x "$noexec/Contents/MacOS/unison-ui-mac"
out=$("$noexec/Contents/MacOS/cltool" 2>"$tmp/err"); rc=$?
[ "$rc" -eq 1 ]; check "non-executable sibling: exit 1" $?

if [ "$fail" -ne 0 ]; then
	echo "test-cltool: FAIL" >&2
	exit 1
fi
echo "test-cltool: PASS"
