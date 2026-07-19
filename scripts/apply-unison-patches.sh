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

# The exact patch set this build expects. Missing any of these is a build
# error, not a silent "apply whatever happens to be in patches/": a dropped
# patch file would otherwise produce a quietly under-patched blob.
REQUIRED_PATCHES="0002-uimacbridge-register-closeConnection.patch 0003-remote-close-and-drain.patch 0004-remote-transport-child-reaper.patch"

if [ ! -f "$ROOT/src/uimacbridge.ml" ]; then
    echo "No upstream Unison checkout at $ROOT/src — skipping patch apply."
    echo "(Vendored blob in vendor/ already has the patches baked in.)"
    exit 0
fi

# Fail loudly if a required patch file is missing.
for name in $REQUIRED_PATCHES; do
    if [ ! -f "$PATCHES/$name" ]; then
        echo "ERROR: required patch missing: $PATCHES/$name" >&2
        echo "       The documented patch set is: $REQUIRED_PATCHES" >&2
        echo "       Restore the missing file (e.g. from version control) before building." >&2
        exit 1
    fi
done

for name in $REQUIRED_PATCHES; do
    abs="$PATCHES/$name"
    # Absolute path so the subshell `cd "$ROOT"` doesn't break a relative one.
    case $abs in /*) : ;; *) abs=$(pwd)/$abs ;; esac

    if ( cd "$ROOT" && git apply --check --whitespace=nowarn -p1 "$abs" ) >/dev/null 2>&1; then
        echo "Applying patch: $name"
        ( cd "$ROOT" && git apply --whitespace=nowarn -p1 "$abs" )
    elif ( cd "$ROOT" && git apply --check -R --whitespace=nowarn -p1 "$abs" ) >/dev/null 2>&1; then
        echo "Patch already applied: $name"
    else
        echo "ERROR: $name is partially applied or incompatible with $ROOT." >&2
        echo "       It does not apply forward cleanly and does not reverse" >&2
        echo "       cleanly — the tree is in neither the pre- nor the post-patch" >&2
        echo "       state. Refusing to build from a partial patch state." >&2
        echo "       Inspect the tree to see what changed, then build from a" >&2
        echo "       clean checkout or a fresh worktree at the documented base" >&2
        echo "       commit (see vendor/README.md)." >&2
        exit 1
    fi
done
