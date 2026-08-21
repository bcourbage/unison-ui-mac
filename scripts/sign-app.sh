#!/bin/sh
# sign-app.sh — sign an app bundle for Developer ID distribution.
#
# Signs every nested code component inside-out (deepest first) with the hardened
# runtime and a secure timestamp, then the app itself. Deliberately NOT
# `--deep` (deprecated, and unreliable for a framework's nested XPC services).
# No entitlements are applied: unison-ui-mac is non-sandboxed and needs none,
# and re-signing without `--entitlements` drops any `get-task-allow` so the
# result can be notarized.
#
# Validated against Apple's notary service: the app binary (OCaml core linked
# in) plus every Sparkle component (Downloader/Installer XPC, Updater.app,
# Autoupdate, the framework) notarize with no entitlements and no library-
# validation exception. The final `codesign --verify --deep --strict` fails
# closed if any nested code was missed.
#
# Usage: sign-app.sh <app-bundle> [identity]
#   identity: a codesign identity string or SHA-1; defaults to $SIGN_DIST_IDENTITY,
#   else the single "Developer ID Application" identity in the keychain.
set -eu

app="${1:?usage: sign-app.sh <app-bundle> [identity]}"
identity="${2:-${SIGN_DIST_IDENTITY:-}}"

if [ ! -d "$app" ]; then
	echo "sign-app: not an app bundle: $app" >&2
	exit 2
fi

if [ -z "$identity" ]; then
	# Resolve the single Developer ID Application identity from the keychain.
	# Refuse on zero or multiple matches rather than guess which to ship with.
	count=$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Developer ID Application' || true)
	if [ "$count" != 1 ]; then
		echo "sign-app: expected exactly one 'Developer ID Application' identity in the keychain (found $count)." >&2
		echo "          Set SIGN_DIST_IDENTITY to choose one explicitly." >&2
		exit 1
	fi
	identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)
fi

# Developer ID signing gets the hardened runtime + a secure timestamp (both
# required for notarization). Ad-hoc ("-", the local no-cert fallback) gets
# neither — there's no certificate or timestamp authority to anchor them, and a
# locally built bundle is never notarized.
sign() {
	echo "  sign: ${1##*/}" >&2
	if [ "$identity" = "-" ]; then
		codesign --force --sign - "$1"
	else
		codesign --force --options runtime --timestamp --sign "$identity" "$1"
	fi
}

echo "sign-app: signing '$app' with [$identity]" >&2

fw="$app/Contents/Frameworks/Sparkle.framework"
if [ -d "$fw" ]; then
	v="$fw/Versions/Current"
	# Sparkle ships its current version under Versions/B; follow whatever
	# Versions/Current resolves to.
	for c in \
		"$v/XPCServices/Downloader.xpc" \
		"$v/XPCServices/Installer.xpc" \
		"$v/Updater.app" \
		"$v/Autoupdate" ; do
		[ -e "$c" ] && sign "$c"
	done
	sign "$fw"
fi

# Defensive: sign any other embedded dylibs/frameworks a build might add. A
# clean Release bundle currently embeds only Sparkle, so these usually match
# nothing; the trailing --verify is the real backstop.
find "$app/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' 2>/dev/null | while IFS= read -r d; do
	sign "$d"
done

# The app itself, last (seals the bundle over the now-signed nested code).
sign "$app"

# Fail closed if anything nested was left unsigned or invalid.
codesign --verify --deep --strict "$app"
echo "sign-app: OK — verified '$app'" >&2
