#!/usr/bin/env bash
# Reproduce the session-scoped CLI options engine prototype and its evidence.
# See docs/cli-session-prefs-prototype-report.md.
#
# Builds the vendored Unison engine objects on the repository's own OCaml path
# (unison/src/Makefile.OCaml, same as `make vendor-blob`; no opam/dune), links
# the prototype against them, runs every asserted case, then restores the tree.
# Exits non-zero if any assertion fails.
#
# Usage:  UNISON_SRC=/path/to/unison/src docs/spikes/run-cli-session-prefs-prototype.sh
set -euo pipefail

UNISON_SRC="${UNISON_SRC:-$HOME/Documents/Sources/unison/src}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROTO="$HERE/cli-session-prefs-prototype.ml"
[ -d "$UNISON_SRC" ] || { echo "UNISON_SRC not found: $UNISON_SRC"; exit 2; }

cd "$UNISON_SRC"
echo "== building engine objects (make -f Makefile.OCaml tui) =="
make Makefile.cfg >/dev/null
make -f Makefile.OCaml tui >/dev/null

cp "$PROTO" prototype2.ml
inc=(-I lwt -I ubase -I system -I system/generic -I lwt/generic -I +unix -I +str)
echo "== compiling + linking the prototype =="
ocamlopt -g "${inc[@]}" -c prototype2.ml
# Same native objects the `unison` tui links (see the tui build's `-o unison`
# line), with main.cmx / linktext.cmx (the UI entry) replaced by prototype2.cmx.
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

U="$(mktemp -d)"
printf '# session A: no path configured\n' > "$U/A.prf"
printf 'path = Preset\n' > "$U/B.prf"

rc=0
echo "##### match (bool, alias-opposite-default, int, BOOLDEF) #####"
EXPECT=match        UNISON="$U" ./prototype2 -batch -confirmbigdeletes=false -maxerrors 5 -fastcheck default || rc=1
echo "##### repeated-list #####"
EXPECT=repeated-list UNISON="$U" ./prototype2 -path A -path B || rc=1
echo "##### path-custom #####"
EXPECT=path-custom  UNISON="$U" ./prototype2 -path Documents || rc=1
echo "##### whitespace #####"
EXPECT=whitespace   UNISON="$U" ./prototype2 -path '  ws  ' || rc=1

echo "== cleanup (restore the unison tree) =="
rm -rf "$U"
rm -f prototype2 prototype2.ml prototype2.cmi prototype2.cmx prototype2.o
make clean >/dev/null

echo "== overall: $([ $rc -eq 0 ] && echo PASS || echo FAIL) =="
exit $rc
