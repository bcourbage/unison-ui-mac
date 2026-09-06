#!/bin/sh
# test-cltool.sh — tests for Sources/CLTool/cltool.c, the `unison` launcher.
#
# Compiles the tool against a throwaway bundle identifier, so the Launch Services
# fallback can never find a real installed app, into a fake bundle whose main
# "executable" is a shell script that records how it was invoked and exits 7.
# No Xcode, no OCaml, no signing identity: cc and the system frameworks only.
set -u

here=$(cd "$(dirname "$0")" && pwd)
src="$here/../Sources/CLTool/cltool.c"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

app="$tmp/Fake.app"
macos="$app/Contents/MacOS"
mkdir -p "$macos" "$tmp/bin"
cat > "$macos/unison-ui-mac" <<'FAKE'
#!/bin/sh
printf 'argv0=%s\n' "$0"
for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
exit 7
FAKE
chmod +x "$macos/unison-ui-mac"

cc -Wall -Wextra -Werror \
	-DCLTOOL_BUNDLE_ID='"net.courbage.unison-ui-mac.cltool-test.invalid"' \
	-framework CoreFoundation -framework CoreServices \
	-o "$macos/cltool" "$src" \
	|| { echo "test-cltool: cannot compile $src" >&2; exit 1; }

# The tool resolves its own path with realpath(3); compare against the same.
real_macos=$(cd "$macos" && pwd -P)
expected_exe="$real_macos/unison-ui-mac"

check() {
	if [ "$2" -eq 0 ]; then r=PASS; else r=FAIL; fail=1; fi
	printf '  %-44s %s\n' "$1" "$r"
}

echo "cltool launcher:"

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
arg=[-version]" ]; check "direct: resolves the sibling executable" $?

# --- No arguments at all ------------------------------------------------------
out=$("$macos/cltool" 2>"$tmp/err"); rc=$?
[ "$rc" -eq 7 ] && [ "$out" = "argv0=$expected_exe" ]; check "direct: no arguments" $?

# --- Copied out of the bundle: fallback finds no app, fails closed -----------
cp "$macos/cltool" "$tmp/unison-copy"
out=$("$tmp/unison-copy" -version 2>"$tmp/err"); rc=$?
[ "$rc" -eq 1 ]; check "copied out: exit 1" $?
[ -z "$out" ]; check "copied out: nothing on stdout" $?
grep -q "cannot locate" "$tmp/err"; check "copied out: stderr names the problem" $?

# --- Symlink into a bundle whose app executable is missing -------------------
broken="$tmp/Broken.app/Contents/MacOS"
mkdir -p "$broken"
cp "$macos/cltool" "$broken/cltool"
ln -s "$broken/cltool" "$tmp/bin/unison-broken"
out=$("$tmp/bin/unison-broken" -version 2>"$tmp/err"); rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ]; check "missing app executable: exit 1, stdout empty" $?

# --- A non-executable sibling must not be exec'd ------------------------------
noexec="$tmp/NoExec.app/Contents/MacOS"
mkdir -p "$noexec"
cp "$macos/cltool" "$noexec/cltool"
: > "$noexec/unison-ui-mac"   # exists, not executable
out=$("$noexec/cltool" 2>"$tmp/err"); rc=$?
[ "$rc" -eq 1 ]; check "non-executable sibling: exit 1" $?

if [ "$fail" -ne 0 ]; then
	echo "test-cltool: FAIL" >&2
	exit 1
fi
echo "test-cltool: PASS"
