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

appcast="$updates_dir/appcast.xml"
if [ ! -f "$appcast" ]; then
	echo "error: generate_appcast did not produce $appcast" >&2
	exit 1
fi

# Fail closed on unsigned enclosures. generate_appcast only WARNS (and still
# exits 0) when the EdDSA key is missing or does not match the app — it then
# emits enclosures with no sparkle:edSignature. Publishing such an appcast
# silently breaks updates for every installed client (Sparkle rejects an
# unsigned archive), so refuse unless EVERY <enclosure> carries a signature.
enclosures=$(grep -c '<enclosure' "$appcast" || true)
signatures=$(grep -o 'sparkle:edSignature="[^"]\{1,\}"' "$appcast" | wc -l | tr -d '[:space:]')
if [ "$enclosures" -eq 0 ]; then
	echo "error: no <enclosure> entries in $appcast — no updates were added." >&2
	exit 1
fi
if [ "$signatures" -lt "$enclosures" ]; then
	echo "error: $appcast has $enclosures enclosure(s) but only $signatures EdDSA signature(s)." >&2
	echo "       An enclosure without sparkle:edSignature means generate_appcast could not sign" >&2
	echo "       it — usually a missing or mismatched key in the keychain. Refusing to publish;" >&2
	echo "       fix the signing key (see docs/sparkle-updates.md) and regenerate." >&2
	exit 1
fi
echo "Wrote: $appcast ($enclosures enclosure(s), all EdDSA-signed)" >&2
