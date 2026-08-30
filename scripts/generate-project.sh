#!/usr/bin/env bash
# Single authority for generating the Xcode project and Resources/Info.plist.
#
# project.yml is the ONLY human-maintained source of truth. The .xcodeproj and
# Resources/Info.plist are generated artifacts, gitignored, and MUST NOT be
# committed. Every supported build/test/open path runs this first (via
# `make generate`), so a stale local copy can never survive as build input:
# `xcodegen generate` rewrites both from project.yml unconditionally.
#
# Invoke via `make generate` — the Makefile exports the variables xcodegen
# substitutes into project.yml (UNISON_VERSION for the vendored-manual path;
# BLOB / OCAMLLIBDIR / STRIPPED_ASMRUN_DIR for the build settings).
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"   # repo root
here="scripts"

# --- Pinned-version gate (single authority: install-xcodegen.sh) -------------
# Reproducible generation requires the pinned XcodeGen. A wrong version fails
# clearly with remediation, unless explicitly overridden for a one-off.
XCODEGEN="${XCODEGEN:-xcodegen}"
pinned="$("$here/install-xcodegen.sh" --print-version)"
have="$("$XCODEGEN" --version 2>/dev/null | awk '{print $2}' || true)"
if [ "$have" != "$pinned" ]; then
  if [ "${XCODEGEN_ALLOW_VERSION_MISMATCH:-0}" = "1" ]; then
    echo "warning: xcodegen '${have:-not found}' != pinned $pinned (XCODEGEN_ALLOW_VERSION_MISMATCH=1)" >&2
  else
    cat >&2 <<EOF
error: xcodegen '${have:-not found}' does not match the pinned $pinned.
       Reproducible project generation requires the pinned version.
       Install it:  make install-xcodegen   (or: sudo scripts/install-xcodegen.sh)
       One-off override: XCODEGEN_ALLOW_VERSION_MISMATCH=1 make generate
EOF
    exit 1
  fi
fi

# xcodegen substitutes ${UNISON_VERSION} into project.yml; the Makefile exports
# it. Fail clearly rather than silently baking an empty path.
: "${UNISON_VERSION:?generate-project.sh must be run via \`make generate\` (UNISON_VERSION is unset)}"

proj="unison-ui-mac.xcodeproj/project.pbxproj"

# xcodegen rewrites project.pbxproj on every run even when the content is
# byte-identical (only the mtime bumps). Preserve the prior mtime on a no-op so
# xcodebuild's incremental state isn't perturbed. (xcodegen already leaves
# Resources/Info.plist untouched when its content is unchanged, and rewrites it
# when it differs — that is the determinism guarantee this whole step relies on.)
ref=""; prev=""
if [ -f "$proj" ]; then
  ref="$(mktemp)"; touch -r "$proj" "$ref"
  prev="$(mktemp)"; cp "$proj" "$prev"
fi

"$XCODEGEN" generate

# Restore project.pbxproj's prior mtime on a no-op rewrite (xcodegen rewrites the
# file each run even when byte-identical). Guarded on $prev so a FRESH generation
# (no prior file — e.g. a clean checkout) skips this block and the script still
# exits 0: a bare trailing `[ -n "$prev" ] && rm` would otherwise make the whole
# script exit non-zero when $prev is empty.
if [ -n "$prev" ]; then
  cmp -s "$prev" "$proj" && touch -r "$ref" "$proj"
  rm -f "$ref" "$prev"
fi
:
