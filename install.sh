#!/usr/bin/env bash
#
# install.sh — sign the built unison-ui-mac.app (Developer ID when a cert is in
# the keychain, else ad-hoc; ADHOC=1 forces ad-hoc), copy it to /Applications,
# clear the quarantine attribute, and (optionally) launch it. See INSTALL.md
# for the equivalent manual commands.
#
# Usage:
#   ./install.sh                     # install into /Applications, then open
#   ./install.sh --dest ~/Applications
#   ./install.sh --no-launch
#
# Exit codes:
#   0  success
#   1  no Release build found (build one first)
#   2  sign / stage / quarantine-strip / swap step failed (existing install kept)

set -euo pipefail

DEST="/Applications"
LAUNCH=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)
            DEST="${2:-}"
            if [[ -z "$DEST" ]]; then
                echo "ERROR: --dest requires a path argument" >&2
                exit 2
            fi
            shift 2
            ;;
        --no-launch)
            LAUNCH=0
            shift
            ;;
        -h|--help)
            sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 2
            ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_NAME="unison-ui-mac.app"
# INSTALL_RELEASE_APP / SIGN_APP are test seams (default to the real paths).
RELEASE_APP="${INSTALL_RELEASE_APP:-$REPO_ROOT/.build/derived/Build/Products/Release/$BUNDLE_NAME}"
SIGN_APP="${SIGN_APP:-$REPO_ROOT/scripts/sign-app.sh}"

# SF8: require a Release build. There is no valid Debug install — sign-app.sh (and
# therefore any shippable install) rejects Debug-shaped bundles, which carry a
# `.debug.dylib`, a preview dylib, and hosted-test frameworks that fail its
# embedded-code whitelist. A Debug fallback would only fail at the signing step,
# or silently ship the wrong bundle, and let a stale Release shadow newer Debug
# work. So accept Release only, matching `make install` and INSTALL.md.
if [[ ! -d "$RELEASE_APP" ]]; then
    echo "ERROR: no Release build found at:" >&2
    echo "  $RELEASE_APP" >&2
    echo "" >&2
    echo "Build one first, then re-run this script:" >&2
    echo "  make build CONFIG=Release     # or simply: make install" >&2
    exit 1
fi
SRC_APP="$RELEASE_APP"

DEST_APP="$DEST/$BUNDLE_NAME"

echo "Source : $SRC_APP  (Release)"
echo "Target : $DEST_APP"
echo ""

# Decide whether we need sudo to write into $DEST.
if [[ -w "$DEST" ]] || ([[ ! -e "$DEST" ]] && [[ -w "$(dirname "$DEST")" ]]); then
    SUDO=""
else
    SUDO="sudo"
    echo "Note: $DEST isn't writable as your user; using sudo for copy/xattr."
    echo ""
fi

mkdir -p "$DEST" 2>/dev/null || $SUDO mkdir -p "$DEST"

# 1. Sign the source bundle in place, inside-out, via scripts/sign-app.sh.
#    Prefer a Developer ID identity when one is in the keychain: it turns on the
#    hardened runtime and gives a stable code identity, so TCC grants survive
#    rebuilds. Fall back to ad-hoc ("-") when no Developer ID cert is present
#    (or when ADHOC=1 is set) — local use only; the quarantine strip below keeps
#    Gatekeeper satisfied for a locally built app. `--deep` is NOT used
#    (deprecated, and unreliable for the nested Sparkle XPC services).
if [[ "${ADHOC:-0}" != "1" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application'; then
    echo "[1/4] Signing $BUNDLE_NAME with Developer ID (hardened runtime)"
    "$SIGN_APP" "$SRC_APP"
else
    echo "[1/4] Ad-hoc signing $BUNDLE_NAME (no Developer ID identity, or ADHOC=1)"
    "$SIGN_APP" "$SRC_APP" -
fi

# atomic_swap <new> <dest>: atomically EXCHANGE two existing directories via
# renameatx_np(RENAME_SWAP) — a single kernel operation. There is no instant where
# <dest> is absent, and a crash/SIGKILL cannot interrupt it mid-way; on failure
# both paths are left untouched. After success <dest> is the new bundle and <new>
# holds the old one. Overridable for tests via INSTALL_SWAP_HELPER.
atomic_swap() {
    if [[ -n "${INSTALL_SWAP_HELPER:-}" ]]; then
        "$INSTALL_SWAP_HELPER" "$1" "$2"
        return
    fi
    $SUDO /usr/bin/python3 - "$1" "$2" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
AT_FDCWD, RENAME_SWAP = -2, 0x2
fn = libc.renameatx_np
fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
if fn(AT_FDCWD, sys.argv[1].encode(), AT_FDCWD, sys.argv[2].encode(), RENAME_SWAP) != 0:
    sys.stderr.write("renameatx_np(RENAME_SWAP) failed: %s\n" % os.strerror(ctypes.get_errno()))
    sys.exit(1)
PY
}

# 2. Stage the new bundle ON THE DESTINATION FILESYSTEM and validate it (SF10). The
#    working install is not touched until a complete, validated copy is ready, so a
#    disk-full, permission, or interrupted copy can never leave no installation.
#    Only STAGE is ever cleaned up — there is no backup path whose loss could
#    destroy the sole good install.
echo "[2/4] Staging the new bundle next to $DEST_APP"
STAGE="$DEST/.$BUNDLE_NAME.new.$$"
cleanup_stage() { $SUDO rm -rf "$STAGE" 2>/dev/null || true; }
trap cleanup_stage EXIT
$SUDO rm -rf "$STAGE"
$SUDO cp -R "$SRC_APP" "$STAGE"

# Validate the staged copy before it can replace a working install: its
# CFBundleExecutable must exist and be executable.
staged_exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$STAGE/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$staged_exe" || ! -x "$STAGE/Contents/MacOS/$staged_exe" ]]; then
    echo "ERROR: the staged copy is invalid (missing main executable)." >&2
    echo "       Leaving the current install at $DEST_APP untouched." >&2
    exit 2
fi

# 3. Strip the quarantine xattr macOS applies to anything copied from another
#    origin, on the STAGED copy (before it is installed), then VERIFY it is gone.
#    `xattr -dr`'s exit status can't tell a benign "attribute absent" from a real
#    permission/I/O failure, so check the END STATE — and capture the verifier's
#    OUTPUT and EXIT STATUS independently (SF9): a failed inspection must not be
#    read as "clean". Only a successful attribute listing that contains no
#    com.apple.quarantine is acceptable.
echo "[3/4] Clearing quarantine attribute"
$SUDO xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
if ! quarantine_attrs="$($SUDO xattr -r "$STAGE" 2>/dev/null)"; then
    echo "ERROR: could not inspect the staged bundle's extended attributes." >&2
    echo "       Refusing to install rather than risk shipping a quarantined app." >&2
    exit 2
fi
case "$quarantine_attrs" in
    *com.apple.quarantine*)
        echo "ERROR: could not clear the quarantine attribute from the staged bundle." >&2
        echo "       Gatekeeper would block the app, so refusing to install." >&2
        exit 2
        ;;
esac

# Install atomically. Replace an existing install with a single RENAME_SWAP (no
# absent-destination window, crash-safe, failure leaves the old app in place); a
# first install is a plain rename, itself atomic. Only after the install succeeds
# is STAGE (now the old bundle, or already consumed) removed.
if [[ -d "$DEST_APP" ]]; then
    if ! atomic_swap "$STAGE" "$DEST_APP"; then
        echo "ERROR: could not install the new bundle (atomic swap failed)." >&2
        echo "       The existing install at $DEST_APP is unchanged." >&2
        exit 2
    fi
elif ! $SUDO mv "$STAGE" "$DEST_APP"; then
    echo "ERROR: could not move the new bundle into $DEST_APP." >&2
    exit 2
fi
trap - EXIT
$SUDO rm -rf "$STAGE"

# 4. Open it (unless --no-launch).
if [[ "$LAUNCH" -eq 1 ]]; then
    echo "[4/4] Launching $DEST_APP"
    open "$DEST_APP"
else
    echo "[4/4] Skipping launch (--no-launch)"
fi

echo ""
echo "Done. Unison-UI-Mac is installed at $DEST_APP."
