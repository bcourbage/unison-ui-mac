#!/usr/bin/env bash
# Single authority for generating the Xcode project and Resources/Info.plist.
#
# project.yml is the ONLY human-maintained source of truth. The .xcodeproj and
# Resources/Info.plist are generated artifacts, gitignored, and MUST NOT be
# committed. Every supported build/test/open path runs this first (via
# `make generate`), so a stale local copy can never survive as build input:
# XcodeGen rewrites both from project.yml unconditionally.
#
# It uses the REPOSITORY-LOCAL pinned XcodeGen (scripts/install-xcodegen.sh),
# invoked by absolute path — never `xcodegen` on PATH. A different global/Homebrew
# xcodegen therefore cannot shadow the pinned copy, and there is no "use whatever
# is installed" escape hatch: reproducibility is not optional. Bumping XcodeGen is
# a reviewed change to install-xcodegen.sh.
#
# Invoke via `make generate` — the Makefile exports the variables xcodegen
# substitutes into project.yml (UNISON_VERSION for the vendored-manual path;
# BLOB / OCAMLLIBDIR / STRIPPED_ASMRUN_DIR for the build settings).
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"   # repo root
here="scripts"

bin="$("$here/install-xcodegen.sh" --print-bin)"
pinned="$("$here/install-xcodegen.sh" --print-version)"
if [ ! -x "$bin" ]; then
  cat >&2 <<EOF
error: the pinned XcodeGen ($pinned) is not installed at:
         $bin
       Install it (repository-local, no sudo, does not touch your global xcodegen):
         make install-xcodegen
EOF
  exit 1
fi
have="$("$bin" --version 2>/dev/null | awk '{print $2}' || true)"
[ "$have" = "$pinned" ] \
  || { echo "error: repository-local xcodegen is '${have:-unknown}', expected $pinned — re-run make install-xcodegen" >&2; exit 1; }

# xcodegen substitutes ${UNISON_VERSION} into project.yml; the Makefile exports
# it. Fail clearly rather than silently baking an empty path.
: "${UNISON_VERSION:?generate-project.sh must be run via \`make generate\` (UNISON_VERSION is unset)}"

proj="unison-ui-mac.xcodeproj/project.pbxproj"

# xcodegen rewrites project.pbxproj on every run even when byte-identical (only
# the mtime bumps). Preserve the prior mtime on a no-op so xcodebuild's
# incremental state isn't perturbed. (xcodegen already leaves Resources/Info.plist
# untouched when unchanged, and rewrites it when it differs — the determinism
# guarantee this step relies on.) Guarded on $prev so a fresh generation (no
# prior file) still exits 0.
ref=""; prev=""
if [ -f "$proj" ]; then
  ref="$(mktemp)"; touch -r "$proj" "$ref"
  prev="$(mktemp)"; cp "$proj" "$prev"
fi

"$bin" generate

if [ -n "$prev" ]; then
  cmp -s "$prev" "$proj" && touch -r "$ref" "$proj"
  rm -f "$ref" "$prev"
fi
:
