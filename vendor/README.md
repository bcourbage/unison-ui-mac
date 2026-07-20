# Vendored upstream artifacts

This directory holds two prebuilt artifacts from the upstream Unison
project, both committed so that everyday `make build` (and end-user
`make install`) skip slow / TeX-dependent generation steps:

1. **`unison-blob-<version>-<arch>.o`** — the compiled OCaml core the
   Swift app links against. Building from source takes 5–10 minutes
   and requires a sibling checkout of `bcpierce00/unison` plus a pinned
   OCaml 5.5.0 toolchain (see Toolchain row below). Regenerated via `make vendor-blob`.
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
| Toolchain | **OCaml 5.5.0** (pinned; enforced by `make check-ocaml-version`). CI/release link against the same 5.5.0 via `ocaml/setup-ocaml`. |
| Built by | `make vendor-blob` → `make apply-patches` then `make -f Makefile.OCaml unison-blob.o` (the OCaml core object only; upstream's own `Unison.app` is not linked — patch 0004 references app-side C symbols it can't resolve). |
| Patches applied | `patches/0002-uimacbridge-register-closeConnection.patch` (adds `Callback.register "closeConnection"` for connection teardown on leave, see issue #6); `patches/0003-remote-close-and-drain.patch` (adds `Remote.drainDroppedConnectionThreads` and drives it from close paths so a closed connection's dormant Lwt receiver thread cannot resume inside the *next* connection's `Lwt_unix.run`, see issue #8); `patches/0004-remote-transport-child-reaper.patch` (adds overridable `Remote.register/retireTransportChild` hooks: the macOS bridge tracks the exact ssh child PID at spawn and, at teardown, SIGKILLs+removes it under a mutex before reaping, backing a pure-C shutdown reaper — see `docs/ssh-reaper-design.md`; CLI/GTK builds keep the default no-ops). `patches/0005-uimacbridge-sync-completion-snapshot.patch` (changes `external syncComplete` to carry the final post-sync `stateItem array` so the macOS bridge marshals ONE bulk per-row completion snapshot — final progress + details — in a single call, eliminating the O(n) per-row `unisonRiToDetails` bridge round-trips the UI previously made at sync completion, see Finding #10; reuses the already-registered accessors, no new OCaml allocation). The former `0001-uimacbridge-register-abortAll.patch` was **retired**: mid-sync abort was merged upstream (PR #1198, commit `2429c6c`) and is present at the base commit above. |
| SHA-256 | `2f345306314305d8e921fea587d913b628b86872553bc3776047ef58fe1dfc89` (was `a57f5c4ec18d96277ac2cde58a7d8f703b012daffdefa42877638671eb062b03` before patch 0005) |
| Mach-O kind | `Mach-O 64-bit object arm64` |
| Size | 5.5 MB (5462568 bytes) |
| Reproducibility | Source, patch set (0002+0003+0004+0005), toolchain (OCaml 5.5.0), and build command above are all pinned. The resulting `.o` is **not byte-identical** across clean rebuilds on this toolchain — observed differing SHA-256 between two same-source builds (OCaml/`ld -r` output is not deterministic here). We therefore do NOT claim a bit-reproducible blob; we pin every input and record the exact checksum of the committed artifact. |

## Provenance — what the current vendored manual is

| Field | Value |
| --- | --- |
| Upstream source | [`doc/unison-manual.tex`](https://github.com/bcpierce00/unison/blob/master/doc/unison-manual.tex) |
| Upstream commit | `745dccd3ba31c5cf0b89b41f3487091b4871ad31` (**not** the same as the blob's `91421d0…`; the blob is 19 commits newer). The rendered HTML still documents the `mergebatch` preference, which upstream later removed from `doc/unison-manual.tex` in `b088176` — a commit that is an ancestor of the blob's `91421d0` but a descendant of this manual's `745dccd`. Regenerate the manual to match the blob commit on the next vendor bump. |
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

Together these reconstruct a functionally-equivalent binary from pinned
inputs (same source commit, same patch set, same OCaml 5.5.0 toolchain,
same build command). It is **not** guaranteed byte-for-byte identical:
the OCaml compiler / `ld -r` output is not deterministic on this
toolchain (observed differing checksums between two same-source builds),
which is an upstream/toolchain property, not something we introduce. No
portion of the blob is original work of this project; the patches are
minimal `Callback`/hook registrations that don't carry significant
authorship.

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
#   - OCaml 5.5.0 (pinned; opam switch or a 5.5.0 Homebrew formula) + `brew install hevea`
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
they'd still need OCaml 5.5.0 (pinned) and the 5–10 min `make macui`
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
