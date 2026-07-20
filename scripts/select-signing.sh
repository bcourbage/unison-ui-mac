#!/bin/sh
# select-signing.sh — Makefile adapter around resolve-signing.sh.
#
# Runs the resolver and re-emits its validated identity/team as two lines for a
# `make` recipe to read (no `eval`). It draws a hard line between two outcomes:
#
#   - The resolver's own POLICY-driven ad-hoc fallback ("-" on line 1) is a
#     normal decision and passes through with exit 0.
#   - An UNEXPECTED resolver failure — nonzero exit, or malformed output (an
#     empty identity line) — is FATAL: this script exits nonzero so the build
#     stops loudly instead of silently continuing with empty signing settings.
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

identity="$(printf '%s\n' "$out" | sed -n '1p')"
team="$(printf '%s\n' "$out" | sed -n '2p')"

if [ -z "$identity" ]; then
    echo "select-signing: malformed resolver output (empty identity); aborting build" >&2
    exit 1
fi

printf '%s\n%s\n' "$identity" "$team"
