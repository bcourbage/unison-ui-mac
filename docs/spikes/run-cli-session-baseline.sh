#!/usr/bin/env bash
# Independent baseline for session-args extraction+application (patches 0007/0009).
# See docs/vendored-patches-upstream.md (patch 0009).
#
# The comparison is CROSS-BINARY, so the reference is the genuinely unmodified
# upstream parser (an in-binary check would run both sides through the patched
# parser):
#   - REFERENCE, built from a PRISTINE worktree: loadTheFile + upstream
#     Prefs.parseCmdLine over the process argv.
#   - CANDIDATE, built from a PATCHED worktree (0002-0009): loadTheFile +
#     Prefs.parseCmdLineArgs (Prefs.commandLineSessionArgs argv).
# Both are run on the SAME argv + profile fixture; the resulting Globals.paths
# must be identical. Disposable git worktrees pinned to the documented revision;
# fail on a compiler mismatch; removed on exit.
#
# Usage:  UNISON_SRC=/path/to/unison/src docs/spikes/run-cli-session-baseline.sh
set -euo pipefail

PINNED_REV="${PINNED_REV:-91421d0617b0fb543c0eee51bcb4d4791d8b0631}"   # v2.54.0-19-g91421d0
PINNED_OCAML="5.5.0"
UNISON_SRC="${UNISON_SRC:-$HOME/Documents/Sources/unison/src}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REF_ML="$HERE/cli-session-baseline-reference.ml"
CAND_ML="$HERE/cli-session-baseline-candidate.ml"
PDIR="$(cd "$HERE/../../patches" && pwd)"
for f in "$REF_ML" "$CAND_ML"; do [ -f "$f" ] || { echo "missing: $f"; exit 2; }; done
[ -d "$UNISON_SRC" ] || { echo "UNISON_SRC not found: $UNISON_SRC"; exit 2; }
OCAML_VER="$(ocamlopt -version)"
[ "$OCAML_VER" = "$PINNED_OCAML" ] || { echo "ERROR: OCaml $OCAML_VER != pinned $PINNED_OCAML"; exit 2; }

REPO="$(cd "$UNISON_SRC" && git rev-parse --show-toplevel)"
W_REF="$(mktemp -d "${TMPDIR:-/tmp}/unison-bref.XXXXXX")"
W_CAND="$(mktemp -d "${TMPDIR:-/tmp}/unison-bcand.XXXXXX")"
U="$(mktemp -d "${TMPDIR:-/tmp}/unison-bprf.XXXXXX")"
cleanup_rc=0
cleanup() {
  cd "$REPO"
  for w in "$W_REF" "$W_CAND"; do
    if [ -d "$w" ] && ! git worktree remove --force "$w" 2>/tmp/brm.$$; then
      echo "CLEANUP WARNING: could not remove $w:"; cat /tmp/brm.$$ || true; cleanup_rc=1
    fi
    rm -f /tmp/brm.$$
  done
  rm -rf "$U"; git worktree prune
}
trap cleanup EXIT

echo "== documented pin: $PINNED_REV  ocaml: $OCAML_VER =="
cd "$REPO"
git worktree add --detach "$W_REF" "$PINNED_REV" >/dev/null    # pristine (upstream parser)
git worktree add --detach "$W_CAND" "$PINNED_REV" >/dev/null
for p in 0002-uimacbridge-register-closeConnection 0003-remote-close-and-drain \
         0004-remote-transport-child-reaper 0005-uimacbridge-sync-completion-snapshot \
         0006-uimacbridge-register-lock 0007-uarg-prefs-session-argv \
         0008-uimacbridge-session-argv 0009-cmdline-session-args-extraction; do
  git -C "$W_CAND" apply --whitespace=nowarn -p1 "$PDIR/$p.patch"
done

inc=(-I lwt -I ubase -I system -I system/generic -I lwt/generic -I +unix -I +str)
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
link_proto() { local ml="$1" d="$2" out="$3" base; base="$(basename "$ml" .ml)"; cp "$ml" "$d/$base.ml"
  ( cd "$d" && ocamlopt -g "${inc[@]}" -c "$base.ml" \
      && ocamlopt -g "${inc[@]}" -o "$out" "${CMXBASE[@]}" "$base.cmx" "${COBJ[@]}" ); }

echo "== building pristine reference + patched candidate engines =="
build_engine "$W_REF"; build_engine "$W_CAND"
link_proto "$REF_ML" "$W_REF/src" refbin
link_proto "$CAND_ML" "$W_CAND/src" candbin

printf 'root = %s/r1\nroot = %s/r2\npath = ProfA\npath = ProfB\n' "$U" "$U" > "$U/Pprec.prf"
printf 'path = FragPath\n' > "$U/frag.prf"
printf 'path = SrcPath\n' > "$U/srcfrag"
mkdir -p "$U/r1" "$U/r2"

rc=0
baseline() { # label -- args...
  local label="$1"; shift 2
  local ref cand
  ref="$( cd "$W_REF/src"  && UPROFILE=Pprec UNISON="$U" ./refbin  "$@" )"
  cand="$( cd "$W_CAND/src" && UPROFILE=Pprec UNISON="$U" ./candbin "$@" )"
  if [ "$ref" = "$cand" ]; then echo "  PASS  $label :: $cand (== pristine upstream)"
  else echo "  FAIL  $label :: upstream=$ref candidate=$cand"; rc=1; fi
}
echo "##### independent baseline: patched extract+apply vs PRISTINE upstream parseCmdLine #####"
baseline "repeated -path" -- -path A -path B
baseline "-include + -path" -- -include frag -path CliX
baseline "-source + -path" -- -source srcfrag -path CliX

echo "== assertions: $([ $rc -eq 0 ] && echo PASS || echo FAIL) =="
cleanup; trap - EXIT
[ $cleanup_rc -eq 0 ] || echo "== cleanup reported problems =="
echo "== overall: $([ $(( rc | cleanup_rc )) -eq 0 ] && echo PASS || echo FAIL) =="
exit $(( rc | cleanup_rc ))
