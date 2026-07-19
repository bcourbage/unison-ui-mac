#!/bin/sh
# Apply the vendored Unison patches with COMPLETE-STATE detection.
#
# The old Makefile logic decided a patch was installed by grepping for a
# single symbol (e.g. `drainDroppedConnectionThreads` in remote.ml). That is
# fail-UNSAFE: patch 0003 touches four files / six hunks, so one symbol being
# present says nothing about the other files — a half-applied tree would be
# silently treated as fully patched and built from.
#
# Instead, per patch, decide the state with strict all-or-nothing dry-runs:
#   1. forward applies cleanly  -> apply it;
#   2. else it reverses cleanly -> already fully applied, no-op;
#   3. else                     -> FAIL LOUDLY (partial or incompatible).
#
# `git apply --check` is used for (1)/(2): it is strict (no fuzz, no skipping
# of already-applied hunks) and non-interactive, unlike BSD `patch`, which
# either prompts on a reversed hunk or (`-f`) silently skips already-applied
# hunks and so cannot tell "fully applied" from "partial". `--whitespace=nowarn`
# keeps a patch that adds a blank/whitespace line from being rejected as a
# whitespace error.
#
# Usage: apply-unison-patches.sh <unison_repo_root> <patches_dir>
#   <unison_repo_root> contains src/ (so `a/src/...` resolves at -p1).
set -eu

ROOT=$1
PATCHES=$2

if [ ! -f "$ROOT/src/uimacbridge.ml" ]; then
    echo "No upstream Unison checkout at $ROOT/src — skipping patch apply."
    echo "(Vendored blob in vendor/ already has the patches baked in.)"
    exit 0
fi

for pf in "$PATCHES"/*.patch; do
    [ -e "$pf" ] || continue
    name=$(basename "$pf")
    # Absolute path so the subshell `cd "$ROOT"` doesn't break a relative one.
    case $pf in /*) abs=$pf ;; *) abs=$(pwd)/$pf ;; esac

    if ( cd "$ROOT" && git apply --check --whitespace=nowarn -p1 "$abs" ) >/dev/null 2>&1; then
        echo "Applying patch: $name"
        ( cd "$ROOT" && git apply --whitespace=nowarn -p1 "$abs" )
    elif ( cd "$ROOT" && git apply --check -R --whitespace=nowarn -p1 "$abs" ) >/dev/null 2>&1; then
        echo "Patch already applied: $name"
    else
        echo "ERROR: $name is partially applied or incompatible with $ROOT." >&2
        echo "       It does not apply forward cleanly and does not reverse" >&2
        echo "       cleanly — the tree is in neither the pre- nor the post-patch" >&2
        echo "       state. Refusing to build from a partial patch state. Reset" >&2
        echo "       the checkout and retry, e.g.:" >&2
        echo "         (cd $ROOT && git checkout -- src && git clean -fd src)" >&2
        exit 1
    fi
done
