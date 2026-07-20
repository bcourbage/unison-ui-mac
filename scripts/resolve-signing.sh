#!/bin/sh
# resolve-signing.sh — resolve the code-signing settings for a build so that
# CODE_SIGN_IDENTITY and DEVELOPMENT_TEAM ALWAYS come from the SAME valid Apple
# Development identity record. Prints two shell assignments on stdout and a
# one-line human diagnostic on stderr:
#
#     RESOLVED_IDENTITY='<sha1-hash | manual-name | ->'
#     RESOLVED_TEAM='<team-id | empty>'
#
# The Makefile `eval`s the stdout and forwards the values to xcodebuild
# (DEVELOPMENT_TEAM is omitted entirely when RESOLVED_TEAM is empty). The
# script ALWAYS exits 0: on any ambiguity, missing piece, or inconsistent
# override it falls back to ad-hoc ("-", no team) rather than forward a partial
# or mismatched identity/team pair.
#
# Policy (matches PR #15):
#   - Release is ALWAYS ad-hoc, even when a signing override is present.
#   - CI (any config) is ad-hoc — runners carry no development certificate.
#   - Local Debug / `make test`: a stable Apple Development signature when a
#     complete, self-consistent identity/team pair is available; else ad-hoc.
#
# Inputs (environment):
#   CONFIG         Debug | Release   (default Debug). Release => ad-hoc.
#   CI             if non-empty      => ad-hoc.
#   SIGN_IDENTITY  manual override.  "-" => ad-hoc. Any other non-empty value
#                  is a manual identity and REQUIRES a matching DEV_TEAM
#                  (both must be supplied together — the team is never
#                  auto-derived for a manually chosen identity).
#   DEV_TEAM       manual team, used only alongside a manual SIGN_IDENTITY.
#
# Overrides apply to Debug / `make test` only; Release ignores them (ad-hoc).
#
# Test seams (default to the real `security` queries; override with canned
# data to exercise the resolution matrix without a live keychain):
#   SIGN_RESOLVER_IDENTITIES_CMD  default: security find-identity -v -p codesigning
#   SIGN_RESOLVER_CERTS_CMD       default: security find-certificate -a -Z -p

set -u

emit() {   # emit <identity> <team> <diagnostic>
    printf "RESOLVED_IDENTITY='%s'\n" "$1"
    printf "RESOLVED_TEAM='%s'\n" "$2"
    printf 'signing: %s\n' "$3" >&2
    exit 0
}

adhoc() {  # adhoc <diagnostic>
    emit '-' '' "$1 -> ad-hoc"
}

CONFIG="${CONFIG:-Debug}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
DEV_TEAM="${DEV_TEAM:-}"

# 1. Release is always ad-hoc (a personal dev cert must never touch a Release
#    artifact); overrides are deliberately ignored here.
[ "$CONFIG" = "Debug" ] || adhoc "Release build (dev cert never on a Release artifact)"

# 2. CI => ad-hoc.
[ -z "${CI:-}" ] || adhoc "CI environment"

# 3. Explicit ad-hoc override.
[ "$SIGN_IDENTITY" != "-" ] || adhoc "SIGN_IDENTITY=-"

# 4. Manual override. A custom identity MUST be paired with an explicit team;
#    the two are used verbatim (assumed to match) and never mixed with an
#    auto-derived value.
if [ -n "$SIGN_IDENTITY" ] && [ -n "$DEV_TEAM" ]; then
    emit "$SIGN_IDENTITY" "$DEV_TEAM" "manual override (identity + team supplied together)"
fi
if [ -n "$SIGN_IDENTITY" ]; then
    adhoc "SIGN_IDENTITY set without a matching DEV_TEAM (supply both, or neither for auto-detect)"
fi
if [ -n "$DEV_TEAM" ]; then
    adhoc "DEV_TEAM set without SIGN_IDENTITY (supply both, or neither for auto-detect)"
fi

# 5. Auto-detection. Take the FIRST valid Apple Development identity and derive
#    BOTH its SHA-1 hash and its team (OU) from that SAME certificate. Only
#    valid identities with a usable private key are listed (security -v +
#    policy codesigning), so a stale/keyless certificate never participates.
identities_cmd="${SIGN_RESOLVER_IDENTITIES_CMD:-security find-identity -v -p codesigning}"
certs_cmd="${SIGN_RESOLVER_CERTS_CMD:-security find-certificate -a -Z -p}"

identities="$($identities_cmd 2>/dev/null || true)"
certs="$($certs_cmd 2>/dev/null || true)"

# Apple Development identity hashes, in listed order:
#   "  1) <40-hex> "Apple Development: ...""
hashes="$(printf '%s\n' "$identities" \
    | awk '/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-Fa-f]+[[:space:]]+"Apple Development/ {print $2}')"

for h in $hashes; do
    # Extract the certificate whose SHA-1 hash equals this identity's hash, then
    # read its OU (the team id) — guaranteeing identity and team share a record.
    team="$(printf '%s\n' "$certs" | awk -v h="$h" '
        /^SHA-1 hash:/ { cur=$3; incert=0; buf="" }
        /-----BEGIN CERTIFICATE-----/ { incert=1 }
        incert { buf=buf $0 "\n" }
        /-----END CERTIFICATE-----/ { if (cur==h) { printf "%s", buf; exit } incert=0 }
    ' | openssl x509 -noout -subject 2>/dev/null \
      | grep -oE 'OU ?= ?[0-9A-Z]+' | head -1 | grep -oE '[0-9A-Z]+$')"
    if [ -n "$team" ]; then
        emit "$h" "$team" "auto-detected identity $h with team $team (same record)"
    fi
done

adhoc "no valid Apple Development identity with a derivable team found"
