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
#   1  built bundle not found
#   2  copy / sign / xattr step failed

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
RELEASE_APP="$REPO_ROOT/.build/derived/Build/Products/Release/$BUNDLE_NAME"
DEBUG_APP="$REPO_ROOT/.build/derived/Build/Products/Debug/$BUNDLE_NAME"

if [[ -d "$RELEASE_APP" ]]; then
    SRC_APP="$RELEASE_APP"
    BUILD_KIND="Release"
elif [[ -d "$DEBUG_APP" ]]; then
    SRC_APP="$DEBUG_APP"
    BUILD_KIND="Debug"
else
    echo "ERROR: no built bundle found." >&2
    echo "Expected one of:" >&2
    echo "  $RELEASE_APP" >&2
    echo "  $DEBUG_APP" >&2
    echo "" >&2
    echo "Run 'make build' first (or 'make build CONFIG=Release' for an" >&2
    echo "optimized build), then re-run this script." >&2
    exit 1
fi

DEST_APP="$DEST/$BUNDLE_NAME"

echo "Source : $SRC_APP  ($BUILD_KIND)"
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
    "$REPO_ROOT/scripts/sign-app.sh" "$SRC_APP"
else
    echo "[1/4] Ad-hoc signing $BUNDLE_NAME (no Developer ID identity, or ADHOC=1)"
    "$REPO_ROOT/scripts/sign-app.sh" "$SRC_APP" -
fi

# 2. Copy into place, replacing any existing install.
echo "[2/4] Copying to $DEST"
if [[ -d "$DEST_APP" ]]; then
    $SUDO rm -rf "$DEST_APP"
fi
$SUDO cp -R "$SRC_APP" "$DEST_APP"

# 3. Strip the quarantine xattr that macOS applies to anything copied
#    from another origin. Without this, Gatekeeper blocks the launch.
echo "[3/4] Clearing quarantine attribute"
$SUDO xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

# 4. Open it (unless --no-launch).
if [[ "$LAUNCH" -eq 1 ]]; then
    echo "[4/4] Launching $DEST_APP"
    open "$DEST_APP"
else
    echo "[4/4] Skipping launch (--no-launch)"
fi

echo ""
echo "Done. Unison-UI-Mac is installed at $DEST_APP."
