#!/usr/bin/env bash
# Fresh-process test of do_unisonInit1's first-load override contract (patch 0008).
# See docs/cli-session-parser-report.md / the PR description.
#
# The hosted XCTest cannot exercise the first load (it cannot control Sys.argv,
# and its `firstTime` is consumed by an earlier test). This runs the REAL
# Uimacbridge.do_unisonInit1 in a genuinely fresh process, with a controlled
# argv, once per scenario. Builds in a DISPOSABLE git worktree pinned to the
# documented vendored revision + OCaml, links uimacbridge.cmx (built by the blob
# target) with no-op C stubs for its externals, and removes the worktree at the
# end. Exits non-zero on any mismatch.
#
# Usage:  UNISON_SRC=/path/to/unison/src docs/spikes/run-cli-session-firstload.sh
set -euo pipefail

PINNED_REV="${PINNED_REV:-91421d0617b0fb543c0eee51bcb4d4791d8b0631}"   # v2.54.0-19-g91421d0
PINNED_OCAML="5.5.0"
UNISON_SRC="${UNISON_SRC:-$HOME/Documents/Sources/unison/src}"
HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$HERE/cli-session-firstload-harness.ml"
STUBS="$HERE/cli-session-firstload-stubs.c"
PDIR="$(cd "$HERE/../../patches" && pwd)"
for f in "$HARNESS" "$STUBS"; do [ -f "$f" ] || { echo "missing: $f"; exit 2; }; done
[ -d "$UNISON_SRC" ] || { echo "UNISON_SRC not found: $UNISON_SRC"; exit 2; }

OCAML_VER="$(ocamlopt -version)"
[ "$OCAML_VER" = "$PINNED_OCAML" ] || { echo "ERROR: OCaml $OCAML_VER != pinned $PINNED_OCAML"; exit 2; }

REPO="$(cd "$UNISON_SRC" && git rev-parse --show-toplevel)"
W="$(mktemp -d "${TMPDIR:-/tmp}/unison-fl.XXXXXX")"
U="$(mktemp -d "${TMPDIR:-/tmp}/unison-flprf.XXXXXX")"
cleanup_rc=0
cleanup() {
  cd "$REPO"
  if [ -d "$W" ] && ! git worktree remove --force "$W" 2>/tmp/flrm.$$; then
    echo "CLEANUP WARNING: could not remove $W:"; cat /tmp/flrm.$$ || true; cleanup_rc=1
  fi
  rm -f /tmp/flrm.$$; rm -rf "$U"; git worktree prune
}
trap cleanup EXIT

echo "== documented pin: $PINNED_REV  ocaml: $OCAML_VER =="
cd "$REPO"
git worktree add --detach "$W" "$PINNED_REV" >/dev/null
for p in 0002-uimacbridge-register-closeConnection 0003-remote-close-and-drain \
         0004-remote-transport-child-reaper 0005-uimacbridge-sync-completion-snapshot \
         0006-uimacbridge-register-lock 0007-uarg-prefs-session-argv \
         0008-uimacbridge-session-argv 0009-cmdline-session-args-extraction; do
  git -C "$W" apply --whitespace=nowarn -p1 "$PDIR/$p.patch"
done

cd "$W/src"
echo "== building engine + uimacbridge.cmx (make -f Makefile.OCaml unison-blob.o) =="
make Makefile.cfg >/dev/null
make -f Makefile.OCaml unison-blob.o >/dev/null

inc=(-I lwt -I ubase -I system -I system/generic -I lwt/generic -I +unix -I +str -I +threads)
cp "$HARNESS" firstload.ml
cc -c -I "$(ocamlc -where)" "$STUBS" -o flstubs.o
ocamlopt -g "${inc[@]}" -c firstload.ml
# tui object set + uimacbridge.cmx (built above) + external stubs + engine C objs.
CMX=(unix.cmxa str.cmxa threads.cmxa ubase/umarshal.cmx ubase/rx.cmx unicode_tables.cmx unicode.cmx bytearray.cmx \
  system/system_generic.cmx system/generic/system_impl.cmx system.cmx ubase/projectInfo.cmx ubase/myMap.cmx \
  ubase/safelist.cmx ubase/util.cmx ubase/uarg.cmx ubase/prefs.cmx ubase/trace.cmx ubase/proplist.cmx \
  lwt/pqueue.cmx lwt/lwt.cmx lwt/lwt_util.cmx lwt/generic/lwt_unix_impl.cmx lwt/lwt_unix.cmx features.cmx \
  uutil.cmx case.cmx pred.cmx terminal.cmx fileutil.cmx name.cmx path.cmx fspath.cmx fs.cmx fingerprint.cmx \
  abort.cmx osx.cmx fswatch.cmx propsdata.cmx props.cmx fileinfo.cmx os.cmx lock.cmx clroot.cmx common.cmx \
  tree.cmx checksum.cmx transfer.cmx xferhint.cmx remote.cmx external.cmx negotiate.cmx globals.cmx \
  fswatchold.cmx fpcache.cmx update.cmx moves.cmx copy.cmx stasher.cmx files.cmx sortri.cmx recon.cmx \
  transport.cmx strings.cmx uicommon.cmx uitext.cmx test.cmx main.cmx uimacbridge.cmx firstload.cmx)
COBJ=(flstubs.o osxsupport.o pty.o bytearray_stubs.o hash_compat.o props_xattr.o props_acl.o copy_stubs.o)
echo "== linking fresh-load harness =="
ocamlopt -g "${inc[@]}" -o firstload "${CMX[@]}" "${COBJ[@]}"

printf 'root = %s/r1\nroot = %s/r2\n' "$U" "$U" > "$U/firstload.prf"
printf 'root = %s/r1\nroot = %s/r2\npath = ProfA\npath = ProfB\n' "$U" "$U" > "$U/Pprec.prf"
printf 'path = FragPath\n' > "$U/frag.prf"    # a profile fragment, included via -include
printf 'path = SrcPath\n' > "$U/srcfrag"      # a bare file (no .prf), included via -source
mkdir -p "$U/r1" "$U/r2"

rc=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "  PASS  $1 :: [$3]"; else echo "  FAIL  $1 :: expected [$2] got [$3]"; rc=1; fi
}
echo "##### first-load contract (each line is a FRESH process, argv carries -path ArgvPath) #####"
out_none=$(SESS=none         UPROFILE=firstload UNISON="$U" ./firstload -path ArgvPath)
check "None: legacy process argv is parsed"            "ArgvPath"    "$out_none"
out_empty=$(SESS=empty        UPROFILE=firstload UNISON="$U" ./firstload -path ArgvPath)
check "Some []: process argv suppressed, none added"   ""           "$out_empty"
out_some=$(SESS="-path SessionPath" UPROFILE=firstload UNISON="$U" ./firstload -path ArgvPath)
check "Some v: process argv suppressed, session applied" "SessionPath" "$out_some"

echo "##### session-args extraction (patch 0009): non-cli_only options only, ordered #####"
e1=$(SESS=extract UNISON="$U" ./firstload -ui graphic -path Documents home)
check "excludes -ui (cli_only) + its value, excludes the profile" "[-path][Documents]" "$e1"
e2=$(SESS=extract UNISON="$U" ./firstload -path A -path B)
check "preserves repeats and order"                    "[-path][A][-path][B]"     "$e2"
e3=$(SESS=extract UNISON="$U" ./firstload -path "  ws  ")
check "preserves whitespace in values"                 "[-path][  ws  ]"          "$e3"
e4=$(SESS=extract UNISON="$U" ./firstload -path -weird)
check "preserves a value that looks like an option"    "[-path][-weird]"          "$e4"
e5=$(SESS=extract UNISON="$U" ./firstload -confirmbigdeletes=false home)
check "preserves the alias as given (non-canonical)"   "[-confirmbigdeletes=false]" "$e5"
e6=$(SESS=extract UNISON="$U" ./firstload -ui graphic home)
check "cli_only-only command line extracts nothing"    ""                          "$e6"
e7=$(SESS=extract UNISON="$U" ./firstload -ui graphic -include frag home)
check "keeps -include (config-bearing cli_only exception)" "[-include][frag]"       "$e7"
e8=$(SESS=extract UNISON="$U" ./firstload -source frag)
check "keeps -source (config-bearing cli_only exception)"  "[-source][frag]"        "$e8"

echo "##### extraction -> application: profile precedence + list accumulation #####"
a1=$(SESS=applyeq UPROFILE=Pprec UNISON="$U" ./firstload -ui graphic -path CliX home)
check "extracted -path accumulates onto the profile's paths" "[ProfA][ProfB][CliX]" "$a1"
a2=$(SESS=applyeq UPROFILE=Pprec UNISON="$U" ./firstload -include frag -path CliX home)
check "-include fragment's path, then -path, accumulate onto profile" "[ProfA][ProfB][FragPath][CliX]" "$a2"
a3=$(SESS=applyeq UPROFILE=Pprec UNISON="$U" ./firstload -source srcfrag -path CliX home)
check "-source file's path, then -path, accumulate onto profile" "[ProfA][ProfB][SrcPath][CliX]" "$a3"

echo "##### independent baseline: extract+apply == original parseCmdLine (same argv, no profile/-ui) #####"
b1=$(SESS=baseline UPROFILE=Pprec UNISON="$U" ./firstload -path A -path B)
check "baseline: repeated -path matches upstream parser"  "REF=[ProfA][ProfB][A][B] NEW=[ProfA][ProfB][A][B] EQ=true" "$b1"
b2=$(SESS=baseline UPROFILE=Pprec UNISON="$U" ./firstload -include frag -path CliX)
check "baseline: -include + -path matches upstream parser" "REF=[ProfA][ProfB][FragPath][CliX] NEW=[ProfA][ProfB][FragPath][CliX] EQ=true" "$b2"
b3=$(SESS=baseline UPROFILE=Pprec UNISON="$U" ./firstload -source srcfrag -path CliX)
check "baseline: -source + -path matches upstream parser"  "REF=[ProfA][ProfB][SrcPath][CliX] NEW=[ProfA][ProfB][SrcPath][CliX] EQ=true" "$b3"

echo "== assertions: $([ $rc -eq 0 ] && echo PASS || echo FAIL) =="
cleanup; trap - EXIT
[ $cleanup_rc -eq 0 ] || echo "== cleanup reported problems =="
echo "== overall: $([ $(( rc | cleanup_rc )) -eq 0 ] && echo PASS || echo FAIL) =="
exit $(( rc | cleanup_rc ))
