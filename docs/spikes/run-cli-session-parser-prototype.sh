#!/usr/bin/env bash
# Reproduce the parser-variant engine prototype and its evidence.
# See docs/cli-session-parser-report.md.
#
# Isolation: this script never builds in, patches, or cleans the caller's
# working tree. It creates two DISPOSABLE git worktrees pinned to a documented
# upstream revision (PINNED_REV below), builds each entirely inside its own
# worktree, and removes both at the end (and on any error, via a trap). Cleanup
# failures are reported, not ignored.
#
# It builds THREE binaries so the comparison uses an INDEPENDENT reference, not
# two paths through the same patch:
#   - reference, from a PRISTINE worktree  -> the unmodified upstream parser
#     (Prefs.parseCmdLine): ground truth for successful parses and for the
#     historical error behavior (exit status, stdout, stderr).
#   - reference, from the PATCHED worktree -> the refactored `parse`, compared
#     against the pristine one to show the refactor is behavior-preserving.
#   - variant,   from the PATCHED worktree -> the new entry point
#     (Prefs.parseCmdLineArgs) under test.
#
# The engine objects are built on the repository's own OCaml path
# (unison/src/Makefile.OCaml, the same path `make vendor-blob` uses; no
# opam/dune). Exits non-zero if any assertion or comparison fails.
#
# Usage:  UNISON_SRC=/path/to/unison/src docs/spikes/run-cli-session-parser-prototype.sh
set -euo pipefail

# Documented reproduction context. Pin to the vendored base so the comparison is
# against a known upstream, independent of any local working-tree modifications.
PINNED_REV="${PINNED_REV:-4f6e8c78b80c21d45b02807071f5dc2715a7eac4}"   # v2.54.0-25-g4f6e8c7
EXPECTED_OCAML="5.5.0"

UNISON_SRC="${UNISON_SRC:-$HOME/Documents/Sources/unison/src}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REF_ML="$HERE/cli-session-parser-reference.ml"
VAR_ML="$HERE/cli-session-parser-variant.ml"
PATCH="$HERE/cli-session-parser.patch"
for f in "$REF_ML" "$VAR_ML" "$PATCH"; do
  [ -f "$f" ] || { echo "missing: $f"; exit 2; }
done
[ -d "$UNISON_SRC" ] || { echo "UNISON_SRC not found: $UNISON_SRC"; exit 2; }

OCAML_VER="$(ocamlopt -version)"
[ "$OCAML_VER" = "$EXPECTED_OCAML" ] || echo "NOTE: ocaml $OCAML_VER, documented $EXPECTED_OCAML (proceeding)"

REPO="$(cd "$UNISON_SRC" && git rev-parse --show-toplevel)"
W_REF="$(mktemp -d "${TMPDIR:-/tmp}/unison-ref.XXXXXX")"
W_VAR="$(mktemp -d "${TMPDIR:-/tmp}/unison-var.XXXXXX")"
U="$(mktemp -d "${TMPDIR:-/tmp}/unison-prf.XXXXXX")"
cleanup_rc=0
cleanup() {
  cd "$REPO"
  for w in "$W_REF" "$W_VAR"; do
    if [ -d "$w" ]; then
      if ! git worktree remove --force "$w" 2>/tmp/wtrm.$$; then
        echo "CLEANUP WARNING: could not remove worktree $w:"; cat /tmp/wtrm.$$ || true
        cleanup_rc=1
      fi
      rm -f /tmp/wtrm.$$
    fi
  done
  rm -rf "$U"
  git worktree prune
}
trap cleanup EXIT

echo "== pinned rev: $PINNED_REV  ocaml: $OCAML_VER =="
cd "$REPO"
git worktree add --detach "$W_REF" "$PINNED_REV" >/dev/null
git worktree add --detach "$W_VAR" "$PINNED_REV" >/dev/null
echo "== applying parser patch to the variant worktree only =="
git -C "$W_VAR" apply "$PATCH"

inc=(-I lwt -I ubase -I system -I system/generic -I lwt/generic -I +unix -I +str)
# Same native objects the `unison` tui links (its `-o unison` line), minus the
# UI entry (main.cmx / linktext.cmx); the prototype cmx is appended per build.
CMXBASE=(unix.cmxa str.cmxa ubase/umarshal.cmx ubase/rx.cmx unicode_tables.cmx unicode.cmx bytearray.cmx \
  system/system_generic.cmx system/generic/system_impl.cmx system.cmx ubase/projectInfo.cmx ubase/myMap.cmx \
  ubase/safelist.cmx ubase/util.cmx ubase/uarg.cmx ubase/prefs.cmx ubase/trace.cmx ubase/proplist.cmx \
  lwt/pqueue.cmx lwt/lwt.cmx lwt/lwt_util.cmx lwt/generic/lwt_unix_impl.cmx lwt/lwt_unix.cmx features.cmx \
  uutil.cmx case.cmx pred.cmx terminal.cmx fileutil.cmx name.cmx path.cmx fspath.cmx fs.cmx fingerprint.cmx \
  abort.cmx osx.cmx fswatch.cmx propsdata.cmx props.cmx fileinfo.cmx os.cmx lock.cmx clroot.cmx common.cmx \
  tree.cmx checksum.cmx transfer.cmx xferhint.cmx remote.cmx external.cmx negotiate.cmx globals.cmx \
  fswatchold.cmx fpcache.cmx update.cmx moves.cmx copy.cmx stasher.cmx files.cmx sortri.cmx recon.cmx \
  transport.cmx strings.cmx uicommon.cmx uitext.cmx test.cmx)
COBJ=(osxsupport.o pty.o bytearray_stubs.o hash_compat.o props_xattr.o props_acl.o copy_stubs.o)

build_engine() { ( cd "$1/src" && make Makefile.cfg >/dev/null && make -f Makefile.OCaml tui >/dev/null ); }
link_proto() { # worktree_src_ml  src_dir  outbin
  local ml="$1" d="$2" out="$3" base
  base="$(basename "$ml" .ml)"
  cp "$ml" "$d/$base.ml"
  ( cd "$d" && ocamlopt -g "${inc[@]}" -c "$base.ml" \
      && ocamlopt -g "${inc[@]}" -o "$out" "${CMXBASE[@]}" "$base.cmx" "${COBJ[@]}" )
}

echo "== building reference (pristine) and variant (patched) engines =="
build_engine "$W_REF"
build_engine "$W_VAR"
# both reference binaries share the argv0 ./parserbin so upstream's error
# messages carry an identical program-name token on each side.
link_proto "$REF_ML" "$W_REF/src" parserbin
link_proto "$REF_ML" "$W_VAR/src" parserbin
link_proto "$VAR_ML" "$W_VAR/src" varbin

REFP="$W_REF/src"   # pristine reference
REFQ="$W_VAR/src"   # patched reference (refactored parse)
VARQ="$W_VAR/src"   # variant

# profile fixtures
printf '# no path configured\n'      > "$U/A.prf"
printf 'path = Preset\n'             > "$U/B.prf"
printf 'path = ProfA\npath = ProfB\n' > "$U/Pprec.prf"

rc=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; rc=1; }

OUTF="$(mktemp)"; ERRF="$(mktemp)"
run() { # dir bin [env NAME=val ...] -- args...  (env pairs before --)
  local dir="$1" bin="$2"; shift 2
  local -a envs=()
  while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done
  shift
  set +e
  # ${envs[@]+...} expands to nothing for an empty array even under `set -u`
  # (macOS bash 3.2 would otherwise abort the subshell on "${envs[@]}").
  ( cd "$dir" && env UNISON="$U" ${envs[@]+"${envs[@]}"} "./$bin" "$@" ) >"$OUTF" 2>"$ERRF"
  RC=$?
  set -e
}

echo
echo "### 1. Successful parses: variant (patched parseCmdLineArgs) vs INDEPENDENT"
echo "###    unpatched reference (parseCmdLine). Compares resulting pref state."
parity() { # label  profile  -- args...
  local label="$1" prof="$2"; shift 2
  run "$REFP" parserbin "UPROFILE=$prof" -- "$@"; local ref="$(cat "$OUTF")"
  run "$VARQ" varbin "EXPECT=dump" "UPROFILE=$prof" -- "$@"; local var="$(cat "$OUTF")"
  if [ "$ref" = "$var" ]; then pass "$label :: $ref"
  else fail "$label"; echo "      ref: $ref"; echo "      var: $var"; fi
}
parity "scalar/bool/alias/BOOLDEF" "" -batch -confirmbigdeletes=false -maxerrors 5 -fastcheck default
parity "-path (CUSTOM)"            "" -path Documents
parity "repeated -path"            "" -path A -path B
parity "whitespace preserved"      "" -path "  ws  "
parity "profile paths only"        "Pprec"
parity "CLI + profile precedence"  "Pprec" -path CliX

echo
echo "### 2. Historical parser fidelity: refactored parse (patched) vs unmodified"
echo "###    parse (pristine). Compares exit status, stdout, and stderr."
fidelity() { # label -- args...
  local label="$1"; shift 2
  run "$REFP" parserbin -- "$@"; local rc1=$RC o1="$(cat "$OUTF")" e1="$(cat "$ERRF")"
  run "$REFQ" parserbin -- "$@"; local rc2=$RC o2="$(cat "$OUTF")" e2="$(cat "$ERRF")"
  if [ "$rc1" = "$rc2" ] && [ "$o1" = "$o2" ] && [ "$e1" = "$e2" ]; then
    pass "$label :: exit=$rc1 identical; msg=[$(echo "$e1" | head -1)]"
  else
    fail "$label"
    echo "      pristine: exit=$rc1 err=[$(echo "$e1" | head -1)]"
    echo "      patched : exit=$rc2 err=[$(echo "$e2" | head -1)]"
    [ "$o1" = "$o2" ] || echo "      (stdout differs)"
  fi
}
fidelity "unknown option"   -- -nosuchopt
fidelity "missing argument" -- -maxerrors
fidelity "malformed value"  -- -maxerrors notanint
fidelity "help"             -- -help

echo
echo "### 3. Variant raises (does not exit) on invalid input, recovery clean"
run "$VARQ" varbin "EXPECT=invalid" --; cat "$OUTF"; [ $RC -eq 0 ] || rc=1

echo
echo "### 4. Session matrix (reload same overrides, later request, precedence, partial apply)"
run "$VARQ" varbin "EXPECT=matrix" --; cat "$OUTF"; [ $RC -eq 0 ] || rc=1

rm -f "$OUTF" "$ERRF"
echo
echo "== assertions: $([ $rc -eq 0 ] && echo PASS || echo FAIL) =="
# Run cleanup now (not only via the trap) so its status is in the exit code.
cleanup; trap - EXIT
[ $cleanup_rc -eq 0 ] || echo "== cleanup reported problems =="
echo "== overall: $([ $(( rc | cleanup_rc )) -eq 0 ] && echo PASS || echo FAIL) =="
exit $(( rc | cleanup_rc ))
