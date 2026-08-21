#!/bin/sh
# verify-appcast-signatures.sh — fail unless EVERY <enclosure> in a Sparkle
# appcast carries a non-empty EdDSA signature.
#
# Counting signatures globally is NOT sufficient: Sparkle also emits
# sparkle:edSignature on release-notes elements, so an unrelated signature can
# make a naive "#enclosures == #signatures" check pass while an actual enclosure
# is unsigned. This checks each <enclosure> element individually via XPath, so a
# single unsigned enclosure fails the whole appcast.
#
# Usage: verify-appcast-signatures.sh <appcast.xml>
# Exit: 0 if every enclosure is signed; non-zero otherwise (fail closed).
set -eu

appcast="${1:-}"
if [ -z "$appcast" ] || [ ! -f "$appcast" ]; then
	echo "usage: $0 <appcast.xml>" >&2
	exit 2
fi
if ! command -v xmllint >/dev/null 2>&1; then
	echo "error: xmllint (libxml2) is required to validate the appcast." >&2
	exit 1
fi

# local-name() matches regardless of namespace prefix, so this catches
# sparkle:edSignature (and any unprefixed edSignature) on the enclosure ELEMENT
# itself — not on siblings like a signed release-notes link.
total_xpath="count(//*[local-name()='enclosure'])"
unsigned_xpath="count(//*[local-name()='enclosure'][not(@*[local-name()='edSignature' and string-length(normalize-space(.)) > 0])])"

total=$(xmllint --xpath "$total_xpath" "$appcast" 2>/dev/null) || {
	echo "error: could not parse $appcast as XML" >&2
	exit 1
}
unsigned=$(xmllint --xpath "$unsigned_xpath" "$appcast" 2>/dev/null) || {
	echo "error: could not parse $appcast as XML" >&2
	exit 1
}

if [ "$total" -lt 1 ]; then
	echo "error: no <enclosure> entries in $appcast — no updates were added." >&2
	exit 1
fi
if [ "$unsigned" -gt 0 ]; then
	echo "error: $unsigned of $total enclosure(s) in $appcast lack a non-empty sparkle:edSignature." >&2
	echo "       generate_appcast only warns (and exits 0) when the signing key is missing or does" >&2
	echo "       not match the app; publishing this appcast would break updates for installed" >&2
	echo "       clients. Fix the signing key (see docs/sparkle-updates.md) and regenerate." >&2
	exit 1
fi
echo "OK: all $total enclosure(s) in $appcast are EdDSA-signed" >&2
