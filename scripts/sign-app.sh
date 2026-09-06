#!/bin/sh
# sign-app.sh — sign an app bundle for Developer ID distribution (or ad-hoc
# locally).
#
# Signs Sparkle's nested components inside-out, then the app: hardened runtime +
# secure timestamp for Developer ID (not `--deep`; no entitlements — the app is
# non-sandboxed, and re-signing without --entitlements drops get-task-allow so
# it notarizes). Pass "-" for ad-hoc (local installs only).
#
# Before signing it STRUCTURALLY VALIDATES the bundle (identity-independent,
# fail-closed):
#   * Sparkle.framework and all four nested components must exist — a stripped
#     Sparkle crashes at launch, and a bare `codesign --verify` only checks the
#     code that remains.
#   * A whitelist inventory rejects ANY embedded code that is not the app's own
#     main binary or inside Sparkle.framework. Mach-O executables are detected
#     by CONTENT, not extension, so a raw helper (e.g. Contents/Helpers/foo)
#     cannot slip past. New embedded code must be whitelisted + signed here.
# Consequently this signs distribution-shaped (Release) bundles; a Debug build
# carrying extra dylibs is rejected by design — build Release to sign.
#
# Usage: sign-app.sh <app-bundle> [identity]
#   identity: a Developer ID Application identity (name or SHA-1); default is
#   $SIGN_DIST_IDENTITY, else the single Developer ID Application identity in the
#   keychain. Pass "-" for ad-hoc (local only).
set -eu

app="${1:?usage: sign-app.sh <app-bundle> [identity]}"
identity="${2:-${SIGN_DIST_IDENTITY:-}}"

[ -d "$app" ] || { echo "sign-app: not an app bundle: $app" >&2; exit 2; }

# --- Resolve / validate the signing identity -------------------------------
if [ -z "$identity" ]; then
	# Auto-resolve the single Developer ID Application identity; refuse on zero
	# or multiple matches rather than guess which to ship with.
	count=$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Developer ID Application' || true)
	[ "$count" = 1 ] || { echo "sign-app: expected exactly one 'Developer ID Application' identity in the keychain (found $count); set SIGN_DIST_IDENTITY." >&2; exit 1; }
	identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)
elif [ "$identity" != "-" ]; then
	# An explicitly supplied identity MUST be a Developer ID Application cert —
	# reject an Apple Development (or other) cert that would sign but not be a
	# valid distribution/notarization identity.
	security find-identity -v -p codesigning | grep 'Developer ID Application' | grep -qF -- "$identity" \
		|| { echo "sign-app: identity '$identity' is not a Developer ID Application identity (use '-' for ad-hoc local signing)." >&2; exit 1; }
fi

# --- Structural validation (identity-independent, fail-closed) -------------
fw="$app/Contents/Frameworks/Sparkle.framework"
[ -d "$fw" ] || { echo "sign-app: required Sparkle.framework not found in $app" >&2; exit 1; }
v="$fw/Versions/Current"
components="XPCServices/Downloader.xpc XPCServices/Installer.xpc Updater.app Autoupdate"
for rel in $components; do
	[ -e "$v/$rel" ] || { echo "sign-app: required Sparkle component missing: Sparkle.framework/Versions/Current/$rel" >&2; exit 1; }
done

main_exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist") \
	|| { echo "sign-app: cannot read CFBundleExecutable from $app/Contents/Info.plist" >&2; exit 1; }
[ -n "$main_exe" ] || { echo "sign-app: empty CFBundleExecutable in $app/Contents/Info.plist" >&2; exit 1; }
main="$app/Contents/MacOS/$main_exe"

# The `unison` command-line launcher ships inside every bundle (project.yml
# embeds the cltool target into Contents/MacOS). A bundle without it would
# install fine and then break every PATH symlink pointing at it.
cli="$app/Contents/MacOS/cltool"
[ -f "$cli" ] || { echo "sign-app: required command-line launcher missing: Contents/MacOS/cltool" >&2; exit 1; }

# Inventory every embedded code object (code bundles + Mach-O files, the latter
# by content) and reject anything outside the whitelist. No `|| true`: a scan
# error must fail the run, not pass silently.
inv=$(mktemp)
files=$(mktemp)
sorted=$(mktemp)
extra=$(mktemp)
# Everything runs OUTSIDE pipes so a failure of find/sort/file trips `set -e`
# (or an explicit check) and aborts — a scan error must never pass as "clean".
# Code bundles by name.
find "$app/Contents" -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -print > "$inv"
# Every Mach-O by CONTENT (thin or fat), not extension. `file`'s exit status is
# checked explicitly: a CLASSIFIER FAILURE aborts, distinct from a successful
# "not Mach-O" answer (which would otherwise let a helper slip through).
find "$app/Contents" -type f -print > "$files"
while IFS= read -r f; do
	if ! ftype=$(file -b "$f" 2>/dev/null); then
		echo "sign-app: could not classify '$f' (file failed) — refusing to sign" >&2
		exit 1
	fi
	case "$ftype" in
		*Mach-O*) printf '%s\n' "$f" >> "$inv" ;;
	esac
done < "$files"
# Sort into a file (not a pipe): under /bin/sh a piped `sort | while` reports
# only the while's status, so a failing sort would yield an empty inventory and
# pass. Redirecting lets `set -e` catch the sort failure.
sort -u "$inv" > "$sorted"
while IFS= read -r p; do
	case "$p" in
		"$main"|"$cli"|"$fw"|"$fw"/*) continue ;;
	esac
	printf '%s\n' "$p" >> "$extra"
done < "$sorted"
rm -f "$inv" "$files" "$sorted"
if [ -s "$extra" ]; then
	echo "sign-app: unexpected embedded code with no explicit signing rule:" >&2
	sed 's/^/  /' "$extra" >&2
	echo "          Whitelist and sign it explicitly in sign-app.sh, or remove it." >&2
	rm -f "$extra"
	exit 1
fi
rm -f "$extra"

# --- Sign inside-out, then the app -----------------------------------------
sign() {
	echo "  sign: ${1##*/}" >&2
	if [ "$identity" = "-" ]; then
		codesign --force --sign - "$1"
	else
		codesign --force --options runtime --timestamp --sign "$identity" "$1"
	fi
}

echo "sign-app: signing '$app' with [$identity]" >&2
for rel in $components; do sign "$v/$rel"; done
sign "$fw"
sign "$cli"
sign "$app"

# Fail closed if anything nested was left unsigned or invalid.
codesign --verify --deep --strict "$app"
echo "sign-app: OK — verified '$app'" >&2
