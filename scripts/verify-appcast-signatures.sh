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

# Match Sparkle's OWN parsing, not a loose name match:
#   - the update element is an RSS <enclosure> in NO namespace (namespace-uri='');
#     a namespaced <evil:enclosure> is not one Sparkle reads.
#   - the signature must be an edSignature attribute in the EXACT Sparkle
#     namespace URI. An unprefixed edSignature, or a foreign-namespaced
#     evil:edSignature, is invisible to Sparkle even though its local name
#     matches — so a global/local-name-only check would fail open, approving a
#     feed whose enclosures Sparkle treats as unsigned.
# local-name() (not a prefix test) is used for the accepted attribute so that any
# prefix bound to the Sparkle URI works (Sparkle keys by namespace, not prefix).
SPARKLE_NS="http://www.andymatuschak.org/xml-namespaces/sparkle"
enclosure_pred="local-name()='enclosure' and namespace-uri()=''"
edsig_pred="local-name()='edSignature' and namespace-uri()='$SPARKLE_NS' and string-length(normalize-space(.)) > 0"
total_xpath="count(//*[$enclosure_pred])"
unsigned_xpath="count(//*[$enclosure_pred][not(@*[$edsig_pred])])"

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
