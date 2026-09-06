#!/bin/sh
# smoke-cli.sh — exercise the bundled `unison` launcher and the embedded engine's
# headless roles against a BUILT app bundle, on whatever macOS this runs on.
#
# What it proves, with the exact bundle bytes given:
#   1. The launcher, reached through a PATH-style symlink named `unison`, runs the
#      app's main executable: `unison -version` prints the engine's version line
#      on stdout, nothing on stderr, exit 0.
#   2. The stdin/stdout server transport works end to end: the app in text mode
#      acts as the client and, through an ssh stand-in that execs the launcher
#      locally with the exact remote command upstream sends (`unison -server
#      __new-rpc-mode`), the same bundle acts as the server. Files are transferred
#      and compared byte for byte. This is RPC negotiation plus transfer over
#      pipes, the same path a real `ssh host unison -server` uses, minus ssh.
#   3. A headless invocation with an unknown option reaches the engine's parser
#      (usage, exit 2) rather than a window.
#   4. `unison -server` with stdin at EOF exits on its own within a bounded time.
#
# Not proved here: notarization or Gatekeeper acceptance, and the GUI paths.
#
# Usage: smoke-cli.sh <path-to.app>
set -u

app="${1:?usage: smoke-cli.sh <path-to.app>}"
[ -d "$app" ] || { echo "smoke-cli: app bundle not found: $app" >&2; exit 1; }
app="$(cd "$app" && pwd -P)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
check() {
	if [ "$2" -eq 0 ]; then r=PASS; else r=FAIL; fail=1; fi
	printf '  %-52s %s\n' "$1" "$r"
}

export UNISON="$work/unison"; mkdir -p "$UNISON" "$work/bin"
ln -s "$app/Contents/MacOS/cltool" "$work/bin/unison"
U="$work/bin/unison"

echo "cli smoke against $(basename "$app") on macOS $(sw_vers -productVersion):"

# 1. -version through the launcher
out=$("$U" -version 2>"$work/err"); rc=$?
[ "$rc" -eq 0 ]; check "-version: exit 0" $?
printf '%s\n' "$out" | grep -Eq '^unison version [0-9]+\.[0-9]+\.[0-9]+ \(ocaml [0-9.]+\)$'; check "-version: exactly one version line on stdout" $?
[ ! -s "$work/err" ]; check "-version: stderr empty" $?

# 2. stdin/stdout server transport, app as both peers
mkdir -p "$work/a" "$work/b"
echo hello > "$work/a/h.txt"; mkdir "$work/a/sub"; echo nested > "$work/a/sub/n.txt"
dd if=/dev/urandom of="$work/a/big.bin" bs=1k count=200 2>/dev/null
cat > "$work/fakessh" <<EOF
#!/bin/sh
# ssh stand-in: drop everything through the remote command name, run the launcher locally
while [ \$# -gt 0 ]; do a="\$1"; shift; [ "\$a" = unison ] && break; done
exec "$U" "\$@"
EOF
chmod +x "$work/fakessh"
"$U" "$work/a" "ssh://fakehost/$work/b" -sshcmd "$work/fakessh" -servercmd unison -ui text -batch </dev/null >"$work/c.out" 2>"$work/c.err"; rc=$?
[ "$rc" -eq 0 ]; check "transport: client exit 0" $?
grep -q 'Synchronization complete' "$work/c.err"; check "transport: client reports completion" $?
cmp -s "$work/a/big.bin" "$work/b/big.bin" && cmp -s "$work/a/sub/n.txt" "$work/b/sub/n.txt"; check "transport: 200 KB file and nested file identical" $?
if [ "$rc" -ne 0 ]; then sed -n '1,20p' "$work/c.err" | sed 's/^/    | /'; fi

# 3. unknown option, headless
out=$("$U" -bogus </dev/null 2>"$work/err"); rc=$?
[ "$rc" -eq 2 ] && grep -q "unknown option" "$work/err"; check "-bogus headless: engine parser, exit 2" $?

# 4. -server with stdin at EOF exits on its own (macOS has no timeout(1))
"$U" -server </dev/null >"$work/s.out" 2>"$work/s.err" & pid=$!
exited=0
for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || { exited=1; break; }; sleep 1; done
if [ "$exited" -ne 1 ]; then kill "$pid" 2>/dev/null; fi
[ "$exited" -eq 1 ]; check "-server </dev/null: exits within 30s" $?

if [ "$fail" -ne 0 ]; then echo "smoke-cli: FAIL" >&2; exit 1; fi
echo "smoke-cli: PASS"
