#!/bin/bash
# Retake the four product screenshots (landing page and README) from a Debug build.
#
#   scripts/capture-site-screenshots.sh
#
# Writes assets/screenshot-<name>-<appearance>.png, where <appearance> is the
# macOS appearance in effect when the script runs. Run it once in Light and once
# in Dark (System Settings > Appearance) to refresh both sets; the site and the
# README show the one matching the visitor's appearance.
#
# What it does: builds a throwaway pair of folders with the same five differences
# every time (one conflict, two changes each way), opens the app on a profile over
# them, and captures each window with its rounded corners and no desktop behind it.
# The Sync settings shot shows both completion options on, as the text beside it
# says they are by default; the script switches the notification option on for the
# capture and puts the stored value back afterward.
#
# Needs: a Debug build (`make build`), and for the terminal running this
# Accessibility and Screen Recording access (System Settings > Privacy & Security).
# It drives the app through System Events, so leave the Mac alone while it runs
# (about 30 seconds). It quits any running copy of the app first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$ROOT/.build/derived/Build/Products/Debug/unison-ui-mac.app}"
CL="$APP/Contents/MacOS/cltool"
BUNDLE_ID="net.courbage.unison-ui-mac"
DEMO=/tmp/uidemo
CONFIG=/tmp/uidemo-config
WORK="$(mktemp -d)"
PROC="unison-ui-mac"      # the process name System Events uses
OWNER="Unison-UI-Mac"     # the window owner name CoreGraphics reports

[ -x "$CL" ] || { echo "No Debug build at $APP (run: make build)" >&2; exit 1; }
if defaults read -g AppleInterfaceStyle >/dev/null 2>&1; then MODE=dark; else MODE=light; fi
echo "Capturing in $MODE appearance"

# --- window-id helper (CoreGraphics), compiled once into the work dir ---------
cat > "$WORK/wid.swift" <<'EOF'
import CoreGraphics
import Foundation
let owner = CommandLine.arguments[1]
let prefix = CommandLine.arguments[2]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list {
    guard (w[kCGWindowOwnerName as String] as? String) == owner,
          (w[kCGWindowLayer as String] as? Int) == 0,
          ((w[kCGWindowName as String] as? String) ?? "").hasPrefix(prefix) else { continue }
    print(w[kCGWindowNumber as String] as! Int)
    break
}
EOF
swiftc -O "$WORK/wid.swift" -o "$WORK/wid"

ax() { osascript -e "tell application \"System Events\" to tell process \"$PROC\" to $1"; }

# capture <window-title-prefix> <output-name>
capture() {
  local id
  id="$("$WORK/wid" "$OWNER" "$1")"
  [ -n "$id" ] || { echo "No window titled '$1*'" >&2; return 1; }
  screencapture -x -o -l "$id" "$ROOT/assets/screenshot-$2-$MODE.png"
  echo "wrote assets/screenshot-$2-$MODE.png"
}

# --- restore state on exit ----------------------------------------------------
ORIG_NOTIFY="$(defaults read "$BUNDLE_ID" sync.complete.notify 2>/dev/null || echo unset)"
cleanup() {
  pkill -x "$PROC" 2>/dev/null || true
  sleep 1
  rm -rf "$DEMO" "$CONFIG" "$WORK"
  case "$ORIG_NOTIFY" in
    unset) defaults delete "$BUNDLE_ID" sync.complete.notify 2>/dev/null || true ;;
    *)     defaults write "$BUNDLE_ID" sync.complete.notify -bool "$([ "$ORIG_NOTIFY" = 1 ] && echo true || echo false)" ;;
  esac
}
trap cleanup EXIT

# --- demo data ----------------------------------------------------------------
pkill -x "$PROC" 2>/dev/null || true
sleep 1
rm -rf "$DEMO" "$CONFIG"
mkdir -p "$DEMO/Laptop/Documents" "$DEMO/Laptop/Photos" "$DEMO/Desktop/Documents" "$DEMO/Desktop/Photos" "$CONFIG"
printf 'root = %s\nroot = %s\n' "$DEMO/Laptop" "$DEMO/Desktop" > "$CONFIG/Home-Sync.prf"
# An archive taken while both sides are still empty, so everything added next is new
# (no first-synchronization warning, and every row shows as a new file).
UNISON="$CONFIG" "$CL" -ui text -batch -silent Home-Sync >/dev/null 2>&1
filler() { head -c "$2" /dev/zero | tr '\0' 'x' > "$1"; }
: > "$DEMO/Laptop/Documents/budget.md"; printf 'Desktop' > "$DEMO/Desktop/Documents/budget.md"   # conflict
filler "$DEMO/Desktop/Documents/Q2-summary.md" 20                                              # Second -> First
filler "$DEMO/Desktop/archive-2025.zip" 7                                                      # Second -> First
filler "$DEMO/Laptop/Documents/Q3-summary.md" 36                                               # First -> Second
filler "$DEMO/Laptop/Photos/hiking-trip.jpg" 17                                                # First -> Second

# --- 1. the reconcile window --------------------------------------------------
open -n --env UNISON="$CONFIG" --env UNISON_AUTOTEST_PROFILE=Home-Sync "$APP" \
  --args -ApplePersistenceIgnoreState YES
for _ in $(seq 1 30); do
  ax 'get name of every static text of window 1' 2>/dev/null | grep -q "items" && break
  sleep 1
done
ax 'set frontmost to true'
ax 'set size of window 1 to {960, 702}'
ax 'set position of window 1 to {200, 100}'
sleep 1
capture "Unison" sync-review

# --- 2. the profile editor, Roots page ----------------------------------------
ax 'click menu item "Profile Editor…" of menu 1 of menu bar item "Edit" of menu bar 1' >/dev/null
sleep 2
ax 'select row 1 of table 1 of scroll area 1 of window "Profile Editor"' >/dev/null
sleep 0.5
ax 'click button "Edit…" of window "Profile Editor"' >/dev/null
sleep 2
ax 'set position of window "Edit Profile — Home-Sync" to {300, 150}'
ax 'select row 2 of table 1 of scroll area 1 of window "Edit Profile — Home-Sync"' >/dev/null
sleep 1
capture "Edit Profile" profile-editor
ax 'click button "Cancel" of window "Edit Profile — Home-Sync"' >/dev/null
sleep 1
ax 'click button "Done" of window "Profile Editor"' >/dev/null
sleep 1

# --- 3. Settings: Sync (both completion options on), then Reconcile -----------
ax 'click menu item "Settings…" of menu 1 of menu bar item 2 of menu bar 1' >/dev/null
sleep 2
ax 'click button "Sync" of toolbar 1 of window "Settings"' >/dev/null
sleep 1.5
if [ "$(defaults read "$BUNDLE_ID" sync.complete.notify 2>/dev/null || echo 0)" != 1 ]; then
  read -r X Y <<<"$(ax 'get position of window "Settings"' | tr -d ',')"
  ax "click at {$X + 24, $Y + 186}" >/dev/null     # the notification checkbox
  sleep 1.5
fi
capture "Settings" settings-sync
ax 'click button "Reconcile" of toolbar 1 of window "Settings"' >/dev/null
sleep 1.5
capture "Settings" settings-reconcile
echo "Done. Review the images before committing."
