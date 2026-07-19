# Vendored upstream artifacts

This directory holds two prebuilt artifacts from the upstream Unison
project, both committed so that everyday `make build` (and end-user
`make install`) skip slow / TeX-dependent generation steps:

1. **`unison-blob-<version>-<arch>.o`** — the compiled OCaml core the
   Swift app links against. Building from source takes 5–10 minutes
   and requires a sibling checkout of `bcpierce00/unison` plus
   `brew install ocaml`. Regenerated via `make vendor-blob`.
2. **`unison-manual-<version>.html`** — the Unison reference manual
   rendered to HTML, shipped inside the `.app` bundle as
   Help → "Unison File Synchronizer Manual". Generated from
   upstream's `doc/unison-manual.tex` via hevea (the same TeX→HTML
   tool upstream's own `doc/Makefile` uses). Regenerated via
   `make vendor-manual`.

Current files:

```
vendor/unison-blob-2.54.0-arm64.o
vendor/unison-manual-2.54.0.html
```

If the file for your architecture isn't here, you have two options:

1. Build it yourself with `make vendor-blob` (requires an upstream
   clone — see below). The resulting file appears here ready to commit.
2. Override the blob path at build time:
   `make build BLOB=/path/to/your/unison-blob.o`

## Provenance — what the current vendored blob is

| Field | Value |
| --- | --- |
| Upstream project | <https://github.com/bcpierce00/unison> |
| Upstream version | **v2.54.0** |
| Upstream commit | `91421d0617b0fb543c0eee51bcb4d4791d8b0631` (`v2.54.0-19-g91421d0`, on `origin/master`) |
| Architecture | `arm64` (Apple Silicon) |
| Built by | upstream's `make macui` after applying the patches in `patches/` |
| Patches applied | `patches/0002-uimacbridge-register-closeConnection.patch` (adds `Callback.register "closeConnection"` for connection teardown on leave, see issue #6); `patches/0003-remote-close-and-drain.patch` (adds `Remote.drainDroppedConnectionThreads` and drives it from close paths so a closed connection's dormant Lwt receiver thread cannot resume inside the *next* connection's `Lwt_unix.run`, see issue #8). The former `0001-uimacbridge-register-abortAll.patch` was **retired**: mid-sync abort was merged upstream (PR #1198, commit `2429c6c`) and is already present at the base commit above, so the patch added nothing to the blob (the previous `apply-patches` grep skipped it). Retiring it keeps the patch set to exactly the two that genuinely apply; it does not change the blob. |
| SHA-256 | `6097fd67900db16cb1d9ba16acc6b4b75a67eca3e8ea0521a4ea39b2d2407eb2` |
| Mach-O kind | `Mach-O 64-bit object arm64` |
| Size | 5.2 MB (5460320 bytes) |

## Provenance — what the current vendored manual is

| Field | Value |
| --- | --- |
| Upstream source | [`doc/unison-manual.tex`](https://github.com/bcpierce00/unison/blob/master/doc/unison-manual.tex) |
| Upstream commit | `745dccd3ba31c5cf0b89b41f3487091b4871ad31` (same as the blob) |
| Renderer | hevea 2.38 (`brew install hevea`) — upstream's own TeX→HTML tool, see their `doc/Makefile` |
| Command | `hevea -fix unison-manual.tex` (run from upstream's `doc/`) |
| Output | self-contained single-file HTML, UTF-8, inlined CSS, no companion assets |
| Size | ~197 KB |
| Copyright | "Copyright 1998-2023, Benjamin C. Pierce" (preserved inline as required by GPLv3 §4) |

## License

Upstream Unison is **GNU GPL v3 or later** (see [LICENSE](../LICENSE)
in this repo and `bcpierce00/unison`'s LICENSE). Both vendored
artifacts here are derivative forms of upstream sources at the
commit hash listed above, distributed under the same license.

### `unison-blob-*.o` (compiled binary)

As required by GPLv3 §6 ("Conveying Non-Source Forms"), the complete
corresponding source for this binary is:

- Upstream Unison at the commit hash above, available at the upstream
  URL above (a public mirror), and
- The patches in [`patches/`](../patches/), applied as documented
  there, and
- The build script: upstream's own Makefile invoked via
  [`make vendor-blob`](../Makefile) in this repo.

Together these reconstruct the binary byte-for-byte (modulo
non-determinism in the OCaml compiler's output, which is a known
upstream property and not something we introduce). No portion of the
blob is original work of this project; the patches are minimal
Callback registrations that don't carry significant authorship.

### `unison-manual-*.html` (rendered manual)

A faithful mechanical rendering of upstream's `doc/unison-manual.tex`
at the commit above. The "Copyright 1998-2023, Benjamin C. Pierce"
notice the TeX source carries is preserved verbatim in the HTML
output (§4 "keep intact all notices"). No portion of the rendered
manual is original work of this project; no edits or annotations
are applied between hevea's output and what we commit. The
corresponding source for §6 purposes is the upstream `.tex` file at
the listed commit plus a hevea installation (`brew install hevea`).

## Rebuilding the vendored artifacts

When upstream Unison bumps version, when our patches change, or when
we add a new architecture, the maintainer regenerates both artifacts
in lockstep so the embedded engine and the bundled manual match:

```sh
# Prerequisites (one-time):
#   - Apple Silicon or Intel Mac
#   - brew install ocaml hevea
#   - A sibling clone of upstream:
git clone https://github.com/bcpierce00/unison.git ../unison
cd ../unison && git checkout <commit>   # or a tag
cd ../unison-ui-mac

# Rebuild + restage:
make vendor-blob       # compiled OCaml core (5–10 min)
make vendor-manual     # rendered HTML manual (~1 s)
```

After regenerating:

1. Update the tables above with the new commit hash + checksum
   (`shasum -a 256 vendor/unison-blob-*.o`).
2. Note any patches added or removed under `patches/`.
3. If this is a Unison major-version bump, update README's
   "Unison version" section too. Also rename the new manual file
   under `vendor/` and update the `path:` entry in `project.yml`
   so XcodeGen picks up the new filename.
4. `git add vendor/ && git commit`

## Why not a git submodule of upstream?

A submodule would let users pull a specific upstream commit but
they'd still need `brew install ocaml` and the 5–10 min `make macui`
on first build. The friction we're removing is the *time* of the
OCaml compile, not the cloning. Vendoring the artifact is the only
way to skip the compile step. The submodule approach is also more
fragile across upstream history rewrites; pinning by commit hash in
this README is just as precise and less mechanical baggage.

## Why not a single universal binary?

Apple Silicon is the only target, so we ship arm64-only. The
Makefile's `ARCH := $(shell uname -m)` pattern leaves the door open
by selecting the right arch-specific vendored blob — drop an
`unison-blob-<version>-x86_64.o` next to the arm64 one (built by
running `make vendor-blob` on an Intel host or under Rosetta) and
Intel users would build out of the box.

## Why not a binary distribution channel?

`unison-blob.o` is a build artifact, not a runtime artifact —
end users never see it because it's linked into `unison-ui-mac.app`
at build time. The full `.app` is the right thing to distribute via
GitHub Releases (and is the planned path; see TODO.md). The vendored
object here is for the build-from-source workflow.
