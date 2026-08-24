#!/bin/sh
# test-verify-bundle-minos.sh — fixture tests for verify-bundle-minos.sh.
#
# Builds throwaway .app layouts with real Mach-O binaries at chosen deployment
# floors (via `clang -mmacosx-version-min`) and asserts the verifier's two-tier
# rule: our own binaries (Contents/MacOS/*) must equal the target, no binary
# (ours or vendored) may exceed it, and it fails closed on an empty bundle.
#
# Run standalone or via `make check-bundle-minos`. No Xcode/OCaml needed.
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$here/scripts/verify-bundle-minos.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

# A trivial translation unit compiled into each fixture binary.
cat > "$work/x.c" <<'EOF'
int fixture_symbol(void) { return 0; }
EOF

# mach_o <out> <min-version>: compile a dylib with the given macOS floor.
mach_o() {
    clang -dynamiclib -mmacosx-version-min="$2" -o "$1" "$work/x.c" 2>/dev/null \
        || { echo "FATAL: could not build fixture $1 @ $2"; exit 2; }
}

# expect <want-exit:pass|fail> <label> -- <verify-bundle-minos args...>
expect() {
    want="$1"; label="$2"; shift 3   # drop want, label, the literal --
    if "$SCRIPT" "$@" >/dev/null 2>&1; then got=pass; else got=fail; fi
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1)); echo "ok   — $label (expected $want)"
    else
        fail=$((fail + 1)); echo "FAIL — $label (expected $want, got $got)"
    fi
}

# newapp <dir>: a Contents/MacOS layout skeleton.
newapp() {
    rm -rf "$1"
    mkdir -p "$1/Contents/MacOS"
    mkdir -p "$1/Contents/Frameworks/Sparkle.framework/Versions/B"
}

# --- Case 1: our binary == target, a vendored framework BELOW target → PASS ---
app="$work/good.app"; newapp "$app"
mach_o "$app/Contents/MacOS/app" 15.0
mach_o "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" 11.0
expect pass "ours==target, vendored<target" -- "$app" 15.0

# --- Case 2: our binary ABOVE target → FAIL (exceeds; wouldn't run on target) ---
app="$work/high.app"; newapp "$app"
mach_o "$app/Contents/MacOS/app" 15.0
expect fail "our binary exceeds target" -- "$app" 14.0

# --- Case 3: our binary BELOW target → FAIL (our == rule) ---
app="$work/low.app"; newapp "$app"
mach_o "$app/Contents/MacOS/app" 13.0
expect fail "our binary below target" -- "$app" 15.0

# --- Case 4: a VENDORED binary above target → FAIL (nothing may exceed) ---
app="$work/vhigh.app"; newapp "$app"
mach_o "$app/Contents/MacOS/app" 15.0
mach_o "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" 26.0
expect fail "vendored binary exceeds target" -- "$app" 15.0

# --- Case 5: empty bundle (no Mach-O) → FAIL closed ---
app="$work/empty.app"; newapp "$app"
printf 'not mach-o\n' > "$app/Contents/MacOS/readme.txt"
expect fail "no Mach-O binaries present" -- "$app" 15.0

# --- Case 6: a vendored binary EXACTLY at target is fine (<= holds) ---
app="$work/vequal.app"; newapp "$app"
mach_o "$app/Contents/MacOS/app" 15.0
mach_o "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" 15.0
expect pass "vendored binary equals target" -- "$app" 15.0

echo ""
echo "verify-bundle-minos fixtures: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
