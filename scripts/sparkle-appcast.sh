#!/bin/sh
# sparkle-appcast.sh — generate (and EdDSA-sign) the Sparkle appcast for a
# folder of update archives.
#
# Thin wrapper around Sparkle's `generate_appcast`: it scans the given folder
# for update archives (.zip/.dmg/.tar.*), signs each with the maintainer's
# EdDSA private key from the login keychain, produces binary deltas against
# older versions present, and writes `appcast.xml` into the folder.
#
# The signing key is read from the keychain by generate_appcast itself; this
# script never sees or handles the private key. See docs/sparkle-updates.md.
#
# Usage:
#   SPARKLE_BIN=/path/to/sparkle/bin ./scripts/sparkle-appcast.sh <updates-dir> [extra generate_appcast args...]
#
# SPARKLE_BIN may be omitted if `generate_appcast` is already on PATH.
set -eu

updates_dir="${1:-}"
if [ -z "$updates_dir" ]; then
	echo "usage: $0 <updates-dir> [extra generate_appcast args...]" >&2
	exit 2
fi
if [ ! -d "$updates_dir" ]; then
	echo "error: '$updates_dir' is not a directory" >&2
	exit 2
fi
shift

# Resolve generate_appcast: prefer SPARKLE_BIN, else PATH.
if [ -n "${SPARKLE_BIN:-}" ]; then
	gen="$SPARKLE_BIN/generate_appcast"
else
	gen="$(command -v generate_appcast || true)"
fi
if [ -z "$gen" ] || [ ! -x "$gen" ]; then
	echo "error: generate_appcast not found." >&2
	echo "       Set SPARKLE_BIN to the Sparkle tools' bin/ directory, or put" >&2
	echo "       generate_appcast on PATH. See docs/sparkle-updates.md ('Getting the tools')." >&2
	exit 1
fi

echo "Generating appcast in: $updates_dir" >&2
"$gen" "$@" "$updates_dir"

# Determine the appcast path generate_appcast actually wrote. It defaults to
# <updates-dir>/appcast.xml, but a caller may redirect it with -o/--output-path
# (which we pass through); validate whatever it actually produced.
appcast="$updates_dir/appcast.xml"
prev=""
for a in "$@"; do
	case "$prev" in
		-o|--output-path) appcast="$a" ;;
	esac
	prev="$a"
done
if [ ! -f "$appcast" ]; then
	echo "error: generate_appcast did not produce $appcast" >&2
	exit 1
fi

# Fail closed unless every Sparkle-parsable enclosure carries its own
# Sparkle-namespaced, 64-byte-shaped edSignature (generate_appcast only warns,
# exit 0, on a missing/mismatched key). This is a structural signature-presence
# and shape check — not cryptographic verification (Sparkle does that on the
# client with the public key).
"$(dirname "$0")/verify-appcast-signatures.sh" "$appcast"
echo "Wrote: $appcast (signature-attribute presence + 64-byte shape check passed)" >&2
