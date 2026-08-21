#!/bin/sh
# select-signing.sh — Makefile adapter around resolve-signing.sh.
#
# Runs the resolver and re-emits its validated identity/team as two lines for a
# `make` recipe to read (no `eval`). It draws a hard line between two outcomes:
#
#   - The resolver's own POLICY-driven ad-hoc fallback ("-" on line 1) is a
#     normal decision and passes through with exit 0.
#   - An UNEXPECTED resolver failure — nonzero exit, or malformed output (an
#     empty identity line, OR more than the two contracted lines) — is FATAL:
#     this script exits nonzero so the build stops loudly instead of silently
#     continuing with empty (or wrongly-parsed) signing settings.
#
# The resolver contract is EXACTLY two lines: identity on line 1, team on
# line 2 (team may be empty — that is the legitimate no-team / ad-hoc shape).
# We deliberately do NOT read just the first two lines and discard the rest:
# extra content means the resolver emitted something we don't understand (a
# stray diagnostic on stdout, a multi-line/newline-bearing identity, a policy
# drift), and silently keeping only lines 1–2 could mask it. Extra content is
# therefore fatal, while an empty second line stays valid.
#
# Output (stdout): line 1 = identity, line 2 = team (may be empty).
# The resolver to run can be overridden with SIGN_RESOLVER (used by tests).

set -u

here="$(cd "$(dirname "$0")" && pwd)"
resolver="${SIGN_RESOLVER:-$here/resolve-signing.sh}"

out="$("$resolver")"
status=$?
if [ "$status" -ne 0 ]; then
    echo "select-signing: signing resolver failed (exit $status); aborting build" >&2
    exit 1
fi

# Reject unexpected extra content. `$(...)` already stripped trailing
# newlines, so a well-formed "identity\nteam\n" arrives as at most two lines
# (one line for the ad-hoc "-" with an empty team). Three or more lines means
# the resolver said more than the contract allows.
line_count="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
if [ "$line_count" -gt 2 ]; then
    echo "select-signing: malformed resolver output ($line_count lines; expected identity + optional team); aborting build" >&2
    exit 1
fi

identity="$(printf '%s\n' "$out" | sed -n '1p')"
team="$(printf '%s\n' "$out" | sed -n '2p')"

if [ -z "$identity" ]; then
    echo "select-signing: malformed resolver output (empty identity); aborting build" >&2
    exit 1
fi

# Enforce the identity/team pairing contract. The resolver emits exactly two
# well-formed shapes; any other combination is malformed and FATAL, so the
# build never proceeds with a mismatched pair:
#   - ad-hoc:  identity "-"       with an EMPTY team.
#   - signing: a real identity    with a NON-EMPTY team.
# The two rejected shapes are an ad-hoc "-" carrying a team, and a real
# identity with no team (which would sign without a resolvable team, exactly
# the mismatch the same-record resolver exists to prevent).
if [ "$identity" = "-" ]; then
    if [ -n "$team" ]; then
        echo "select-signing: malformed resolver output (ad-hoc identity '-' paired with a non-empty team '$team'); aborting build" >&2
        exit 1
    fi
else
    if [ -z "$team" ]; then
        echo "select-signing: malformed resolver output (signing identity with an empty team); aborting build" >&2
        exit 1
    fi
fi

printf '%s\n%s\n' "$identity" "$team"
