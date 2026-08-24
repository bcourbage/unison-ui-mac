#!/bin/sh
# test-install.sh — fixture tests for install.sh's SF8–SF10 hardening.
#
# Drives the real install.sh through its test seams (INSTALL_RELEASE_APP, SIGN_APP,
# --dest, --no-launch, ADHOC=1, and a fake `xattr` on PATH) against throwaway
# bundles, asserting the behaviours the pre-hardening script lacked:
#   SF8  — only a Release build is accepted; a missing Release fails clearly (no
#          Debug fallback, which sign-app.sh would reject anyway).
#   SF9  — the quarantine strip is VERIFIED; a strip that cannot clear the
#          attribute fails the install instead of reporting success.
#   SF10 — the new bundle is staged and validated before the old install is
#          touched, so any pre-swap failure leaves the working install in place.
#
# Run standalone or via `make check-install`. No Xcode/OCaml/sudo needed.
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$here/install.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
note() { # note <ok|FAIL> <label>
    if [ "$1" = ok ]; then pass=$((pass + 1)); echo "ok   — $2"; else fail=$((fail + 1)); echo "FAIL — $2"; fi
}

# A no-op stand-in for scripts/sign-app.sh: only checks it got a bundle dir.
stub_sign="$work/stub-sign.sh"
cat > "$stub_sign" <<'EOF'
#!/bin/sh
[ -d "$1" ] || { echo "stub-sign: not a dir: $1" >&2; exit 3; }
exit 0
EOF
chmod +x "$stub_sign"

# make_bundle <path> <with_main:0|1>: a minimal .app; with_main=0 omits the
# executable the Info.plist names, so validation must reject it.
make_bundle() {
    mkdir -p "$1/Contents/MacOS"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string unison-ui-mac' "$1/Contents/Info.plist" >/dev/null
    if [ "$2" = 1 ]; then
        printf '#!/bin/sh\nexit 0\n' > "$1/Contents/MacOS/unison-ui-mac"
        chmod +x "$1/Contents/MacOS/unison-ui-mac"
    fi
}

run_install() { # run_install <release_app> <dest> [extra PATH prefix]
    # shellcheck disable=SC2086
    env ${3:+PATH="$3:$PATH"} \
        INSTALL_RELEASE_APP="$1" SIGN_APP="$stub_sign" ADHOC=1 \
        "$INSTALL" --no-launch --dest "$2" >/dev/null 2>"$work/err.txt"
}

# --- SF8: no Release build -> exit 1, clear message, nothing installed ---------
dest="$work/d8"; mkdir -p "$dest"
if run_install "$work/does-not-exist.app" "$dest"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 1 ] && grep -qi "no Release build" "$work/err.txt" && [ ! -e "$dest/unison-ui-mac.app" ]; then r=ok; else r=FAIL; fi
note "$r" "SF8: missing Release build fails with exit 1 and a clear message"

# --- happy path: installs, no staging leftovers -------------------------------
good="$work/Release/unison-ui-mac.app"; make_bundle "$good" 1
dest="$work/dok"; mkdir -p "$dest"
if run_install "$good" "$dest"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 0 ] && [ -x "$dest/unison-ui-mac.app/Contents/MacOS/unison-ui-mac" ] \
    && [ -z "$(find "$dest" -maxdepth 1 -name '.unison-ui-mac.app.*')" ]; then r=ok; else r=FAIL; fi
note "$r" "happy path installs the Release bundle and leaves no staging files"

# --- SF10: invalid staged copy -> old install preserved, exit 2 ---------------
bad="$work/Bad/unison-ui-mac.app"; make_bundle "$bad" 0   # Info.plist names an exe that is absent
dest="$work/d10"; mkdir -p "$dest/unison-ui-mac.app/Contents/MacOS"
echo OLD > "$dest/unison-ui-mac.app/OLD_MARKER"
if run_install "$bad" "$dest"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 2 ] && [ -f "$dest/unison-ui-mac.app/OLD_MARKER" ] \
    && [ -z "$(find "$dest" -maxdepth 1 -name '.unison-ui-mac.app.*')" ]; then r=ok; else r=FAIL; fi
note "$r" "SF10: a bad staged copy leaves the existing install intact (exit 2, rollback)"

# --- SF9: quarantine cannot be cleared -> exit 2, old install preserved --------
fakebin="$work/fakebin"; mkdir -p "$fakebin"
cat > "$fakebin/xattr" <<'EOF'
#!/bin/sh
# Simulate a real removal failure and report the attribute as still present.
case "$1" in
    -dr) echo "xattr: [Errno 1] Operation not permitted" >&2; exit 1 ;;
    -rp) echo "$3: 0081;deadbeef;Safari;"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$fakebin/xattr"
dest="$work/d9"; mkdir -p "$dest/unison-ui-mac.app/Contents/MacOS"
echo OLD > "$dest/unison-ui-mac.app/OLD_MARKER"
if run_install "$good" "$dest" "$fakebin"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 2 ] && grep -qi "could not clear the quarantine" "$work/err.txt" \
    && [ -f "$dest/unison-ui-mac.app/OLD_MARKER" ]; then r=ok; else r=FAIL; fi
note "$r" "SF9: an unclearable quarantine fails the install (exit 2), old install preserved"

echo ""
echo "install.sh fixtures: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
