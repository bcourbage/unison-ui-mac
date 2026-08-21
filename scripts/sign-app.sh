#!/bin/sh
# sign-app.sh — sign an app bundle for Developer ID distribution (or ad-hoc
# locally).
#
# Signs Sparkle's nested components inside-out, then the app, with the hardened
# runtime + a secure timestamp for Developer ID. Not `--deep` (deprecated, and
# unreliable for a framework's nested XPC services). No entitlements: the app is
# non-sandboxed, and re-signing without `--entitlements` also drops
# `get-task-allow` so the result notarizes.
#
# Sparkle is a REQUIRED, hard-linked dependency: the framework and all four
# nested components must exist and are signed EXPLICITLY — a build missing any
# of them is broken and fails here rather than shipping (an app that dlopen-links
# a stripped Sparkle crashes at launch, and a bare `codesign --verify` only
# checks the code that remains). For distribution signing, any OTHER embedded
# code is rejected: adding a dependency must come with an explicit signing rule
# below, so nothing rides along unaccounted-for behind the final --verify (which
# would happily accept a valid ad-hoc nested framework).
#
# Usage: sign-app.sh <app-bundle> [identity]
#   identity: a Developer ID Application identity (name or SHA-1); defaults to
#   $SIGN_DIST_IDENTITY, else the single Developer ID Application identity in the
#   keychain. Pass "-" for ad-hoc signing (local installs only).
set -eu

app="${1:?usage: sign-app.sh <app-bundle> [identity]}"
identity="${2:-${SIGN_DIST_IDENTITY:-}}"

[ -d "$app" ] || { echo "sign-app: not an app bundle: $app" >&2; exit 2; }

if [ -z "$identity" ]; then
	# Auto-resolve the single Developer ID Application identity (a Developer ID
	# by construction); refuse on zero or multiple matches rather than guess.
	count=$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Developer ID Application' || true)
	[ "$count" = 1 ] || { echo "sign-app: expected exactly one 'Developer ID Application' identity in the keychain (found $count); set SIGN_DIST_IDENTITY." >&2; exit 1; }
	identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)
elif [ "$identity" != "-" ]; then
	# An explicitly supplied identity MUST be a Developer ID Application identity.
	# Reject an Apple Development (or any other) cert: it would sign and verify
	# locally but is not a valid distribution/notarization identity.
	security find-identity -v -p codesigning | grep 'Developer ID Application' | grep -qF -- "$identity" \
		|| { echo "sign-app: identity '$identity' is not a Developer ID Application identity (use '-' for ad-hoc local signing)." >&2; exit 1; }
fi

sign() {
	echo "  sign: ${1##*/}" >&2
	if [ "$identity" = "-" ]; then
		codesign --force --sign - "$1"
	else
		codesign --force --options runtime --timestamp --sign "$identity" "$1"
	fi
}

echo "sign-app: signing '$app' with [$identity]" >&2

# Sparkle: required framework + all four nested components, signed inside-out.
fw="$app/Contents/Frameworks/Sparkle.framework"
[ -d "$fw" ] || { echo "sign-app: required Sparkle.framework not found in $app" >&2; exit 1; }
v="$fw/Versions/Current"
components="XPCServices/Downloader.xpc XPCServices/Installer.xpc Updater.app Autoupdate"
for rel in $components; do
	[ -e "$v/$rel" ] || { echo "sign-app: required Sparkle component missing: Sparkle.framework/Versions/Current/$rel" >&2; exit 1; }
done
for rel in $components; do
	sign "$v/$rel"
done
sign "$fw"

# Distribution signing: reject any embedded code we have no explicit rule for,
# so a new dependency can't ride along un(properly)-signed behind the final
# --verify. Ad-hoc local installs are lenient — a Debug bundle carries extra
# dylibs, and the build's existing signatures + --verify are enough locally.
if [ "$identity" != "-" ]; then
	unexpected=$(find "$app/Contents" \
		\( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' \) \
		! -path "$fw" ! -path "$fw/*" 2>/dev/null || true)
	if [ -n "$unexpected" ]; then
		echo "sign-app: unexpected embedded code with no explicit signing rule:" >&2
		printf '%s\n' "$unexpected" | sed 's/^/  /' >&2
		echo "          Add an explicit signing rule for it in sign-app.sh, then retry." >&2
		exit 1
	fi
fi

# The app itself, last (seals the bundle over the now-signed nested code).
sign "$app"

# Fail closed if anything nested was left unsigned or invalid.
codesign --verify --deep --strict "$app"
echo "sign-app: OK — verified '$app'" >&2
