#!/usr/bin/env bash
# Reproduce the session-scoped CLI options engine prototype (Prefs.loadStrings
# adapter) and its evidence. See docs/cli-session-prefs-prototype-report.md.
#
# Isolation: this script never builds in or cleans the caller's working tree. It
# creates a DISPOSABLE git worktree pinned to a documented upstream revision,
# builds the vendored engine objects there on the repository's own OCaml path
# (unison/src/Makefile.OCaml, same as `make vendor-blob`; no opam/dune), links
# the prototype there, runs every asserted case, and removes the worktree at the
# end (and on any error, via a trap). Cleanup failures are reported, not ignored.
# This half needs no engine source patch (loadStrings already exists), so the
# worktree stays pristine.
#
# Exits non-zero if any assertion fails.
#
# Usage:  UNISON_SRC=/path/to/unison/src docs/spikes/run-cli-session-prefs-prototype.sh
set -euo pipefail

# Documented reproduction context: the SAME upstream commit and OCaml toolchain
# the app vendors (vendor/README.md, Makefile OCAML_PINNED_VERSION).
PINNED_REV="${PINNED_REV:-91421d0617b0fb543c0eee51bcb4d4791d8b0631}"   # v2.54.0-19-g91421d0
PINNED_OCAML="5.5.0"

UNISON_SRC="${UNISON_SRC:-$HOME/Documents/Sources/unison/src}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROTO="$HERE/cli-session-prefs-prototype.ml"
[ -f "$PROTO" ] || { echo "missing: $PROTO"; exit 2; }
[ -d "$UNISON_SRC" ] || { echo "UNISON_SRC not found: $UNISON_SRC"; exit 2; }

OCAML_VER="$(ocamlopt -version)"
if [ "$OCAML_VER" != "$PINNED_OCAML" ]; then
  echo "ERROR: OCaml $OCAML_VER != pinned $PINNED_OCAML (the vendored blob is ABI-locked to $PINNED_OCAML)." >&2
  exit 2
fi

REPO="$(cd "$UNISON_SRC" && git rev-parse --show-toplevel)"
W="$(mktemp -d "${TMPDIR:-/tmp}/unison-adapter.XXXXXX")"
U="$(mktemp -d "${TMPDIR:-/tmp}/unison-prf.XXXXXX")"
cleanup_rc=0
cleanup() {
  cd "$REPO"
  if [ -d "$W" ]; then
    if ! git worktree remove --force "$W" 2>/tmp/wtrm.$$; then
      echo "CLEANUP WARNING: could not remove worktree $W:"; cat /tmp/wtrm.$$ || true
      cleanup_rc=1
    fi
    rm -f /tmp/wtrm.$$
  fi
  rm -rf "$U"
  git worktree prune
}
trap cleanup EXIT

echo "== documented pin: $PINNED_REV  ocaml: $OCAML_VER =="
cd "$REPO"
git worktree add --detach "$W" "$PINNED_REV" >/dev/null

cd "$W/src"
echo "== building engine objects (make -f Makefile.OCaml tui) =="
make Makefile.cfg >/dev/null
make -f Makefile.OCaml tui >/dev/null

cp "$PROTO" prototype2.ml
inc=(-I lwt -I ubase -I system -I system/generic -I lwt/generic -I +unix -I +str)
echo "== compiling + linking the prototype =="
ocamlopt -g "${inc[@]}" -c prototype2.ml
# Same native objects the `unison` tui links (its `-o unison` line), with
# main.cmx / linktext.cmx (the UI entry) replaced by prototype2.cmx.
CMX=(unix.cmxa str.cmxa ubase/umarshal.cmx ubase/rx.cmx unicode_tables.cmx unicode.cmx bytearray.cmx \
  system/system_generic.cmx system/generic/system_impl.cmx system.cmx ubase/projectInfo.cmx ubase/myMap.cmx \
  ubase/safelist.cmx ubase/util.cmx ubase/uarg.cmx ubase/prefs.cmx ubase/trace.cmx ubase/proplist.cmx \
  lwt/pqueue.cmx lwt/lwt.cmx lwt/lwt_util.cmx lwt/generic/lwt_unix_impl.cmx lwt/lwt_unix.cmx features.cmx \
  uutil.cmx case.cmx pred.cmx terminal.cmx fileutil.cmx name.cmx path.cmx fspath.cmx fs.cmx fingerprint.cmx \
  abort.cmx osx.cmx fswatch.cmx propsdata.cmx props.cmx fileinfo.cmx os.cmx lock.cmx clroot.cmx common.cmx \
  tree.cmx checksum.cmx transfer.cmx xferhint.cmx remote.cmx external.cmx negotiate.cmx globals.cmx \
  fswatchold.cmx fpcache.cmx update.cmx moves.cmx copy.cmx stasher.cmx files.cmx sortri.cmx recon.cmx \
  transport.cmx strings.cmx uicommon.cmx uitext.cmx test.cmx prototype2.cmx)
COBJ=(osxsupport.o pty.o bytearray_stubs.o hash_compat.o props_xattr.o props_acl.o copy_stubs.o)
ocamlopt -g "${inc[@]}" -o prototype2 "${CMX[@]}" "${COBJ[@]}"

printf '# session A: no path configured\n' > "$U/A.prf"
printf 'path = Preset\n' > "$U/B.prf"

rc=0
echo "##### match (bool, alias-opposite-default, int, BOOLDEF) #####"
EXPECT=match         UNISON="$U" ./prototype2 -batch -confirmbigdeletes=false -maxerrors 5 -fastcheck default || rc=1
echo "##### repeated-list #####"
EXPECT=repeated-list UNISON="$U" ./prototype2 -path A -path B || rc=1
echo "##### path-custom #####"
EXPECT=path-custom   UNISON="$U" ./prototype2 -path Documents || rc=1
echo "##### whitespace #####"
EXPECT=whitespace    UNISON="$U" ./prototype2 -path '  ws  ' || rc=1

echo "== assertions: $([ $rc -eq 0 ] && echo PASS || echo FAIL) =="
cleanup; trap - EXIT
[ $cleanup_rc -eq 0 ] || echo "== cleanup reported problems =="
echo "== overall: $([ $(( rc | cleanup_rc )) -eq 0 ] && echo PASS || echo FAIL) =="
exit $(( rc | cleanup_rc ))
