#!/usr/bin/env bash
# Reproduce the parser-variant engine prototype and its evidence.
# See docs/cli-session-parser-report.md.
#
# Isolation: this script never builds in, patches, or cleans the caller's
# working tree. It creates two DISPOSABLE git worktrees pinned to the DOCUMENTED
# vendored revision (vendor/README.md), builds each entirely inside its own
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
# opam/dune). Exits non-zero if any assertion or comparison fails. The guard used
# for successful-parse comparisons is itself unit-tested (section 0) to prove it
# rejects a nonzero exit, a missing state record, and a mismatch.
set -euo pipefail

# Documented reproduction context: the SAME upstream commit and OCaml toolchain
# the app vendors (vendor/README.md, Makefile OCAML_PINNED_VERSION). The
# comparison must run against what ships, not a newer upstream.
PINNED_REV="${PINNED_REV:-91421d0617b0fb543c0eee51bcb4d4791d8b0631}"   # v2.54.0-19-g91421d0
PINNED_OCAML="5.5.0"

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
if [ "$OCAML_VER" != "$PINNED_OCAML" ]; then
  echo "ERROR: OCaml $OCAML_VER != pinned $PINNED_OCAML (the vendored blob is ABI-locked to $PINNED_OCAML)." >&2
  exit 2
fi

REPO="$(cd "$UNISON_SRC" && git rev-parse --show-toplevel)"
W_REF="$(mktemp -d "${TMPDIR:-/tmp}/unison-ref.XXXXXX")"
W_VAR="$(mktemp -d "${TMPDIR:-/tmp}/unison-var.XXXXXX")"
U="$(mktemp -d "${TMPDIR:-/tmp}/unison-prf.XXXXXX")"
T="$(mktemp -d "${TMPDIR:-/tmp}/unison-io.XXXXXX")"
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
  rm -rf "$U" "$T"
  git worktree prune
}
trap cleanup EXIT

echo "== documented pin: $PINNED_REV  ocaml: $OCAML_VER =="
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

OUTF="$T/out"; ERRF="$T/err"
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

# --- successful-parse guard, evaluated as a pure function so it can be unit
# --- tested. Inputs via globals PRC/PVC (exit codes) and PREF/PVAR (stdout).
# --- Echoes "pass :: <state>" or "fail: <reason>".
guard() {
  if [ "$PRC" -ne 0 ] || [ "$PVC" -ne 0 ]; then echo "fail: nonzero exit (ref=$PRC var=$PVC)"; return; fi
  case "$PREF" in path=*) ;; *) echo "fail: no state record in reference output"; return;; esac
  case "$PVAR" in path=*) ;; *) echo "fail: no state record in variant output"; return;; esac
  if [ "$PREF" = "$PVAR" ]; then echo "pass :: $PREF"; else echo "fail: state mismatch"; fi
}

echo
echo "### 0. Guard self-test (prove the successful-parse check rejects false passes)"
gtest() { # desc expect(pass|fail) PRC PVC PREF PVAR
  local desc="$1" exp="$2"; PRC="$3"; PVC="$4"; PREF="$5"; PVAR="$6"
  local g got=fail; g="$(guard)"; case "$g" in pass*) got=pass;; esac
  if [ "$got" = "$exp" ]; then pass "self-test: $desc -> $got"
  else fail "self-test: $desc expected $exp got $got ($g)"; fi
}
gtest "reference process failed"        fail 1 0 ""          ""
gtest "variant process failed"          fail 0 1 ""          ""
gtest "exit 0 but empty output"         fail 0 0 ""          ""
gtest "exit 0 but no state record"      fail 0 0 "usage..."  "usage..."
gtest "state mismatch"                  fail 0 0 "path=[a]"  "path=[b]"
gtest "clean match passes"              pass 0 0 "path=[a]"  "path=[a]"

echo
echo "### 1. Successful parses: variant (patched parseCmdLineArgs) vs INDEPENDENT"
echo "###    unpatched reference (parseCmdLine). Requires exit 0 + a state record."
parity() { # label  profile  -- args...
  local label="$1" prof="$2"; shift 2
  run "$REFP" parserbin "UPROFILE=$prof" -- "$@"; PRC=$RC; PREF="$(cat "$OUTF")"
  run "$VARQ" varbin "EXPECT=dump" "UPROFILE=$prof" -- "$@"; PVC=$RC; PVAR="$(cat "$OUTF")"
  local g; g="$(guard)"
  case "$g" in pass*) pass "$label ${g#pass }";; *) fail "$label ($g); ref=[$PREF] var=[$PVAR]";; esac
}
parity "scalar/bool/alias/BOOLDEF" "" -batch -confirmbigdeletes=false -maxerrors 5 -fastcheck default
parity "-path (CUSTOM)"            "" -path Documents
parity "repeated -path"            "" -path A -path B
parity "whitespace preserved"      "" -path "  ws  "
parity "profile paths only"        "Pprec"
parity "CLI + profile precedence"  "Pprec" -path CliX

echo
echo "### 2. Historical parser fidelity: refactored parse (patched) vs unmodified"
echo "###    parse (pristine). Requires exit 2 + a case-specific diagnostic, and"
echo "###    compares the COMPLETE stdout and stderr streams (file compare)."
fidelity() { # label  diag_substr  where(err|out)  -- args...
  local label="$1" sub="$2" where="$3"; shift 3; shift   # drop label,sub,where and the --
  run "$REFP" parserbin -- "$@"; local rc1=$RC; cp "$OUTF" "$T/o1"; cp "$ERRF" "$T/e1"
  run "$REFQ" parserbin -- "$@"; local rc2=$RC; cp "$OUTF" "$T/o2"; cp "$ERRF" "$T/e2"
  local diag; [ "$where" = err ] && diag="$T/e1" || diag="$T/o1"
  if [ "$rc1" != 2 ] || [ "$rc2" != 2 ]; then
    fail "$label (expected exit 2, got ref=$rc1 patched=$rc2)"
  elif ! grep -qF "$sub" "$diag"; then
    fail "$label (missing case-specific diagnostic: '$sub')"
  elif cmp -s "$T/o1" "$T/o2" && cmp -s "$T/e1" "$T/e2"; then
    pass "$label :: exit 2, diagnostic present, full streams identical"
  else
    fail "$label (streams differ between pristine and patched parse)"
  fi
}
fidelity "unknown option"   "unknown option"        err -- -nosuchopt
fidelity "missing argument" "needs an argument"     err -- -maxerrors
fidelity "malformed value"  "wrong argument"        err -- -maxerrors notanint
fidelity "help"             "Basic options:"        out -- -help

echo
echo "### 3. Variant raises (does not exit) on invalid input, recovery clean"
run "$VARQ" varbin "EXPECT=invalid" --; cat "$OUTF"; [ $RC -eq 0 ] || rc=1

echo
echo "### 4. Session matrix (reload same overrides, later request, precedence, partial apply)"
run "$VARQ" varbin "EXPECT=matrix" --; cat "$OUTF"; [ $RC -eq 0 ] || rc=1

echo
echo "== assertions: $([ $rc -eq 0 ] && echo PASS || echo FAIL) =="
# Run cleanup now (not only via the trap) so its status is in the exit code.
cleanup; trap - EXIT
[ $cleanup_rc -eq 0 ] || echo "== cleanup reported problems =="
echo "== overall: $([ $(( rc | cleanup_rc )) -eq 0 ] && echo PASS || echo FAIL) =="
exit $(( rc | cleanup_rc ))
