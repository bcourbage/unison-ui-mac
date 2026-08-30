#!/usr/bin/env bash
# Single source of truth for the pinned, checksum-verified XcodeGen.
#
# It installs into an IGNORED, REPOSITORY-LOCAL path (.tools/xcodegen/<version>/)
# — never /usr/local, never with sudo, and it does NOT touch the developer's
# global or Homebrew xcodegen. The generation step invokes that exact binary
# (via `--print-bin`), so a different `xcodegen` earlier on PATH cannot shadow it.
#
# FAIL-CLOSED: an install is "complete" only when the binary reports the pinned
# version AND the SettingPresets resources are present. A missing-presets install
# still runs but silently emits a materially different project.pbxproj, so the
# binary bytes are staged in a temp sibling, VALIDATED, and only then moved into
# the final versioned directory; `--verify` re-checks completeness cheaply and is
# run by every generation.
#
# Consulted by scripts/generate-project.sh (local), ci.yml, release.yml,
# vendor-blob.yml. To bump XcodeGen, change the two constants here ONLY (a
# reviewed change — re-diff the generated project).
#
# Usage:
#   scripts/install-xcodegen.sh                 # install into .tools/ (idempotent, fail-closed)
#   scripts/install-xcodegen.sh --verify        # validate the installed copy (exit non-zero if incomplete)
#   scripts/install-xcodegen.sh --print-version # pinned version
#   scripts/install-xcodegen.sh --print-sha     # pinned zip sha256
#   scripts/install-xcodegen.sh --print-bin     # absolute path to the pinned binary
set -euo pipefail

XCODEGEN_VERSION="2.44.1"
# sha256 of https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.zip
XCODEGEN_ZIP_SHA256="a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73"
# Content digest of the COMPLETE extracted tree (bin/ + share/) for this version,
# computed once from the checksum-verified archive (see tree_digest()). This
# validates the WHOLE SettingPresets tree — enumerating individual presets is
# brittle (xcodegen consumes many, e.g. Product_Platform/*), so any missing or
# modified file changes this digest and fails verification. Recompute + update it
# together with the version/zip-sha above on a bump (a reviewed change).
XCODEGEN_TREE_SHA256="5b5ad7ca7d5a77eadb7f2d5a5e54e8f4e97f3d40c437a999f6293c65dd177890"

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/.tools/xcodegen/$XCODEGEN_VERSION"
bin="$dest/bin/xcodegen"

# tree_digest <dir>: content digest of bin/ + share/ under <dir> — sorted
# relative paths each hashed, then the whole listing hashed. Deterministic for a
# given file set + contents (metadata-independent). Empty on failure.
tree_digest() {
  ( cd "$1" 2>/dev/null \
      && find bin share -type f 2>/dev/null | LC_ALL=C sort \
      | xargs shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}' )
}

# verify_dir <dir>: 0 iff <dir> holds a complete pinned install — the binary
# reports the pinned version AND the full bin/+share/ tree matches the pinned
# digest (so no consumed preset can be missing or altered).
verify_dir() {
  local d="$1"
  local b="$d/bin/xcodegen"
  local ver dg
  [ -x "$b" ] || { echo "  missing binary: $b" >&2; return 1; }
  ver="$("$b" --version 2>/dev/null | awk '{print $2}' || true)"
  [ "$ver" = "$XCODEGEN_VERSION" ] || { echo "  wrong version at $b: '${ver:-none}' != $XCODEGEN_VERSION" >&2; return 1; }
  dg="$(tree_digest "$d")"
  [ "$dg" = "$XCODEGEN_TREE_SHA256" ] \
    || { echo "  tree digest mismatch at $d ('${dg:-none}') — incomplete or modified install" >&2; return 1; }
  return 0
}

case "${1:-install}" in
  --print-version) printf '%s\n' "$XCODEGEN_VERSION"; exit 0 ;;
  --print-sha)     printf '%s\n' "$XCODEGEN_ZIP_SHA256"; exit 0 ;;
  --print-bin)     printf '%s\n' "$bin"; exit 0 ;;
  --verify)
    if verify_dir "$dest"; then
      echo "xcodegen $XCODEGEN_VERSION verified (binary + presets) at $bin"; exit 0
    fi
    echo "::error::repository-local XcodeGen at $dest is incomplete or wrong-version" >&2
    exit 1 ;;
  install) ;;
  *) echo "usage: $0 [install|--verify|--print-version|--print-sha|--print-bin]" >&2; exit 2 ;;
esac

# Idempotent: a COMPLETE install (not merely a present binary) is a no-op.
if verify_dir "$dest" 2>/dev/null; then
  echo "xcodegen $XCODEGEN_VERSION already present and complete at $bin"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

echo "${XCODEGEN_ZIP_SHA256}  $work/xcodegen.zip" | shasum -a 256 -c - \
  || { echo "::error::XcodeGen zip failed SHA-256 verification (supply-chain guard)" >&2; exit 1; }

unzip -q "$work/xcodegen.zip" -d "$work"

# Stage bin/ + share/ in a temp SIBLING of $dest, validate the STAGED copy, then
# atomically move it into place. An interrupted copy therefore never becomes the
# live install; the worst case is an absent $dest that the next run reinstalls.
mkdir -p "$(dirname "$dest")"
staged="$(mktemp -d "$(dirname "$dest")/.staging-${XCODEGEN_VERSION}.XXXXXX")"
cp -R "$work/xcodegen/bin" "$work/xcodegen/share" "$staged/"
verify_dir "$staged" \
  || { echo "::error::staged XcodeGen is incomplete (bad download/extract) — not installing" >&2; rm -rf "$staged"; exit 1; }

rm -rf "$dest"
mv "$staged" "$dest"

verify_dir "$dest" \
  || { echo "::error::XcodeGen install failed validation after move" >&2; exit 1; }
echo "xcodegen $XCODEGEN_VERSION installed and verified (binary + presets) at $bin"
