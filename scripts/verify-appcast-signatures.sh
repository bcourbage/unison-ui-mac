#!/bin/sh
# verify-appcast-signatures.sh — release gate: fail unless every enclosure that
# Sparkle would parse carries a Sparkle-namespaced edSignature attribute whose
# value decodes to a 64-byte (Ed25519-shaped) signature.
#
# This mirrors Sparkle's parser structurally; it does NOT cryptographically
# verify the signatures (that needs the referenced archive bytes plus the public
# key, and is Sparkle's job on the client). It exists to catch the realistic
# release-tooling failure: generate_appcast only WARNS (exit 0) when the signing
# key is missing or does not match, emitting enclosures with no usable signature,
# which would silently break updates for every installed client.
#
# Usage: verify-appcast-signatures.sh <appcast.xml>
# Exit: 0 if every parsed enclosure has a 64-byte-shaped Sparkle edSignature;
#       non-zero otherwise (fail closed).
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
if ! command -v openssl >/dev/null 2>&1; then
	echo "error: openssl is required to check signature length." >&2
	exit 1
fi

SPARKLE_NS="http://www.andymatuschak.org/xml-namespaces/sparkle"

# ENCLOSURE NODE SET — mirror Sparkle's actual parsing:
#   - Location: Sparkle reads an enclosure only as a direct child of <item> (the
#     main update) or of a namespaced <sparkle:deltas> under an item (deltas). A
#     signed enclosure anywhere else (e.g. <channel><metadata>, <item><metadata>)
#     installs nothing, so matching //enclosure would fail open.
#   - Name: Sparkle matches by the qualified name "enclosure" (Foundation's
#     node.name), so an element in a foreign DEFAULT namespace (unprefixed,
#     name()='enclosure') IS parsed — but a prefixed <evil:enclosure> is not.
#     The main arm also excludes the Sparkle namespace itself (a sparkle-ns child
#     is keyed "sparkle:enclosure", not "enclosure").
enclosures="/rss/channel/item/*[name()='enclosure' and namespace-uri()!='$SPARKLE_NS'] | /rss/channel/item/*[local-name()='deltas' and namespace-uri()='$SPARKLE_NS']/*[name()='enclosure']"

# SIGNATURE ATTRIBUTE — an edSignature attribute in the EXACT Sparkle namespace
# URI (any prefix bound to that URI; Sparkle keys by namespace, not prefix).
# Attributes never inherit a default namespace, so an unprefixed edSignature is
# in no namespace and correctly excluded here.
edsig_pred="local-name()='edSignature' and namespace-uri()='$SPARKLE_NS' and string-length(normalize-space(.)) > 0"

xpath_count() {
	xmllint --xpath "$1" "$appcast" 2>/dev/null || {
		echo "error: could not parse $appcast as XML" >&2
		exit 1
	}
}

total=$(xpath_count "count($enclosures)")
unsigned=$(xpath_count "count(($enclosures)[not(@*[$edsig_pred])])")

if [ "$total" -lt 1 ]; then
	echo "error: no Sparkle-parsable <enclosure> entries in $appcast — no updates were added." >&2
	exit 1
fi
if [ "$unsigned" -gt 0 ]; then
	echo "error: $unsigned of $total enclosure(s) in $appcast lack a non-empty sparkle:edSignature." >&2
	echo "       generate_appcast only warns (and exits 0) when the signing key is missing or does" >&2
	echo "       not match the app; publishing this appcast would break updates for installed" >&2
	echo "       clients. Fix the signing key (see docs/sparkle-updates.md) and regenerate." >&2
	exit 1
fi

# Shape check: each signature must decode to exactly 64 bytes (Ed25519). A
# present-but-malformed value (e.g. a truncated stub) is one Sparkle rejects, so
# reject it here rather than reporting a false "signed".
nsig=$(xpath_count "count(($enclosures)/@*[$edsig_pred])")
i=1
while [ "$i" -le "$nsig" ]; do
	value=$(xmllint --xpath "string((($enclosures)/@*[$edsig_pred])[$i])" "$appcast" 2>/dev/null || true)
	bytes=$(printf '%s' "$value" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')
	if [ "$bytes" -ne 64 ]; then
		echo "error: an enclosure's sparkle:edSignature in $appcast decodes to $bytes bytes, not 64" >&2
		echo "       (not a well-formed Ed25519 signature). Sparkle would reject it; refusing to publish." >&2
		exit 1
	fi
	i=$((i + 1))
done

echo "OK: $total enclosure(s) in $appcast each carry a Sparkle-namespaced, 64-byte edSignature (attribute present + well-formed; not cryptographically verified)" >&2
