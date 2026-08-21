#!/bin/sh
# resolve-signing.sh — resolve the code-signing settings for a build so that
# CODE_SIGN_IDENTITY and DEVELOPMENT_TEAM ALWAYS come from the SAME valid Apple
# Development identity record.
#
# OUTPUT (stdout): exactly two lines — identity on line 1, team on line 2
# (team may be empty). Values are emitted verbatim; the consumer reads them
# with line-oriented parsing and never `eval`s them, so spaces, apostrophes,
# quotes, `$`, `;` etc. in a legitimate identity name are safe. A one-line
# human diagnostic is written to stderr.
#
# EXIT STATUS:
#   0  a decision was made (a real identity OR a policy-driven ad-hoc "-").
#   >0 an UNEXPECTED/internal error (e.g. a value would contain a newline,
#      which can't be represented in the two-line contract). Callers must treat
#      a nonzero exit as fatal — it is NOT the same as the ad-hoc fallback.
#
# INPUTS (environment — passed by the Makefile via `export`, never interpolated
# into recipe text, so hostile values can't be executed):
#   CONFIG         Debug | Release   (default Debug). Release => ad-hoc.
#   CI             if non-empty      => ad-hoc.
#   SIGN_IDENTITY  manual override.  "-" => ad-hoc. Any other non-empty value is
#                  a manual identity (a SHA-1 hash or an exact identity name)
#                  and REQUIRES a matching DEV_TEAM. The pair is VERIFIED
#                  against the keychain (a valid identity matching SIGN_IDENTITY
#                  must have team == DEV_TEAM); an unverifiable/mismatched pair
#                  falls back to ad-hoc rather than signing with a wrong pair.
#   DEV_TEAM       manual team, used only alongside a manual SIGN_IDENTITY.
#
# Overrides apply to Debug / `make test` only; Release ignores them (ad-hoc).
#
# Test seams (default to the real `security` queries; override with canned data
# to drive the matrix without a live keychain):
#   SIGN_RESOLVER_IDENTITIES_CMD  default: security find-identity -v -p codesigning
#   SIGN_RESOLVER_CERTS_CMD       default: security find-certificate -a -Z -p

set -u

nl='
'

emit() {   # emit <identity> <team> <diagnostic>
    # Newlines can't be represented in the two-line output contract. A real
    # identity/team never contains one; if it somehow does, fail loudly rather
    # than emit ambiguous output.
    case "$1$2" in
        *"$nl"*)
            echo "resolve-signing: internal error — resolved value contains a newline" >&2
            exit 3 ;;
    esac
    printf '%s\n%s\n' "$1" "$2"
    printf 'signing: %s\n' "$3" >&2
    exit 0
}

adhoc() {  # adhoc <diagnostic>
    emit '-' '' "$1 -> ad-hoc"
}

CONFIG="${CONFIG:-Debug}"
CI="${CI:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
DEV_TEAM="${DEV_TEAM:-}"

identities_cmd="${SIGN_RESOLVER_IDENTITIES_CMD:-security find-identity -v -p codesigning}"
certs_cmd="${SIGN_RESOLVER_CERTS_CMD:-security find-certificate -a -Z -p}"

# team_for_hash <sha1> — print the OU (team id) of the certificate whose SHA-1
# hash equals <sha1>, taken from that SAME certificate; empty if not found.
team_for_hash() {
    $certs_cmd 2>/dev/null | awk -v h="$1" '
        /^SHA-1 hash:/ { cur=$3; incert=0; buf="" }
        /-----BEGIN CERTIFICATE-----/ { incert=1 }
        incert { buf=buf $0 "\n" }
        /-----END CERTIFICATE-----/ { if (cur==h) { printf "%s", buf; exit } incert=0 }
    ' | openssl x509 -noout -subject 2>/dev/null \
      | grep -oE 'OU ?= ?[0-9A-Z]+' | head -1 | grep -oE '[0-9A-Z]+$'
}

# hashes_matching_selector <selector> — SHA-1 hashes of VALID identities whose
# hash OR exact quoted name equals <selector>. Used to verify a manual pair.
hashes_matching_selector() {
    $identities_cmd 2>/dev/null | awk -v sel="$1" '
        /^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-Fa-f]+[[:space:]]+"/ {
            hash=$2
            name=$0
            sub(/^[^"]*"/, "", name)   # strip through the first quote
            sub(/"[^"]*$/, "", name)   # strip from the last quote
            if (hash==sel || name==sel) print hash
        }'
}

# 1. Release is always ad-hoc (a personal dev cert must never touch a Release
#    artifact); overrides are deliberately ignored here.
[ "$CONFIG" = "Debug" ] || adhoc "Release build (dev cert never on a Release artifact)"

# 2. CI => ad-hoc.
[ -z "$CI" ] || adhoc "CI environment"

# 3. Explicit ad-hoc override.
[ "$SIGN_IDENTITY" != "-" ] || adhoc "SIGN_IDENTITY=-"

# 4. Manual override. BOTH values are required, and the pair is VERIFIED against
#    a single valid keychain record (same-record identity+team) before use.
if [ -n "$SIGN_IDENTITY" ] || [ -n "$DEV_TEAM" ]; then
    if [ -z "$SIGN_IDENTITY" ] || [ -z "$DEV_TEAM" ]; then
        adhoc "incomplete manual override (need both SIGN_IDENTITY and DEV_TEAM)"
    fi
    # A newline in an override value can't name a real identity and can't be
    # represented in the two-line output — reject up front (clean ad-hoc,
    # avoids feeding a newline into the matcher).
    case "$SIGN_IDENTITY$DEV_TEAM" in
        *"$nl"*) adhoc "manual override value contains a newline" ;;
    esac
    for h in $(hashes_matching_selector "$SIGN_IDENTITY"); do
        if [ "$(team_for_hash "$h")" = "$DEV_TEAM" ]; then
            emit "$SIGN_IDENTITY" "$DEV_TEAM" \
                "manual override verified against keychain record"
        fi
    done
    adhoc "manual override unverified (no valid identity matching SIGN_IDENTITY has team '$DEV_TEAM')"
fi

# 5. Auto-detection. First VALID Apple Development identity; derive BOTH its
#    hash and team from that SAME certificate. `security find-identity -v -p
#    codesigning` lists only identities with a usable private key, so a
#    stale/keyless certificate never participates.
hashes="$($identities_cmd 2>/dev/null | awk '/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-Fa-f]+[[:space:]]+"Apple Development/ {print $2}')"
for h in $hashes; do
    t="$(team_for_hash "$h")"
    if [ -n "$t" ]; then
        emit "$h" "$t" "auto-detected identity $h with team $t (same record)"
    fi
done

adhoc "no valid Apple Development identity with a derivable team found"
