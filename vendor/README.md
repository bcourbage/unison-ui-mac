# Vendored OCaml blob

This directory holds the prebuilt OCaml object file that the Swift app
links against. Building it from upstream source takes 5–10 minutes and
requires a sibling checkout of `bcpierce00/unison`; committing the
artifact here means everyday `make build` (and end-user `make install`)
just compile Swift + link, which is a few seconds instead of minutes.

The current vendored file is named after the upstream Unison version
and the build host's CPU architecture:

```
vendor/unison-blob-2.54.0-arm64.o
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
| Upstream commit | `745dccd3ba31c5cf0b89b41f3487091b4871ad31` (`v2.54.0-11-g745dccd`) |
| Architecture | `arm64` (Apple Silicon) |
| Built by | upstream's `make macui` after applying the patch in `patches/` |
| Patches applied | `patches/0001-uimacbridge-register-abortAll.patch` (adds `Callback.register "abortAll"` for the mid-sync Stop button) |
| SHA-256 | `bd47202eeb57b73486523612ad7e9da43df5f5f5e389f87b3ae1d4323931e9f7` |
| Mach-O kind | `Mach-O 64-bit object arm64` |
| Size | 5.1 MB |

## License

Upstream Unison is **GNU GPL v3 or later** (see [LICENSE](../LICENSE)
in this repo and `bcpierce00/unison`'s LICENSE). This object file is
a compiled form of that source plus the patches under `patches/`. As
required by GPLv3 §6 ("Conveying Non-Source Forms"), the complete
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

## Rebuilding the vendored blob

When upstream Unison bumps version, when our patches change, or when
we add a new architecture, the maintainer regenerates the blob:

```sh
# Prerequisites (one-time):
#   - Apple Silicon or Intel Mac
#   - brew install ocaml
#   - A sibling clone of upstream:
git clone https://github.com/bcpierce00/unison.git ../unison
cd ../unison && git checkout <commit>   # or a tag
cd ../unison-ui-mac

# Rebuild + restage:
make vendor-blob
```

After `make vendor-blob`:

1. Update the table above with the new commit hash + checksum
   (`shasum -a 256 vendor/unison-blob-*.o`).
2. Note any patches added or removed under `patches/`.
3. If this is a Unison major-version bump, update README's
   "Unison version" section too.
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

OCaml's native compiler emits single-arch output per invocation
(the vendored `.o` here is `Mach-O 64-bit object arm64`), and
Homebrew's OCaml runtime libraries (`libasmrun.a`, `libthreadsnat.a`,
`libunixnat.a`, `libcamlstrnat.a`) are also installed single-arch
per brew prefix — `arm64` under `/opt/homebrew/lib/ocaml`, `x86_64`
under `/usr/local/lib/ocaml`. A universal build is possible: the
standard Apple approach is to build the whole `.app` once on each
architecture and `lipo` the final Mach-O executables together (this
is what Xcode does internally when you set `ARCHS = arm64 x86_64`
*and* both architectures' link-time dependencies are available on
disk). `lipo`-ing only the intermediate `.o` doesn't get you there
on its own — the runtime libs still need to be combined somehow.

For now we ship arm64-only since Apple Silicon is the only target.
The Makefile's `ARCH := $(shell uname -m)` pattern leaves the door
open by selecting the right arch-specific vendored blob — drop an
`unison-blob-<version>-x86_64.o` next to the arm64 one (built by
running `make vendor-blob` on an Intel host or under Rosetta) and
Intel users would build out of the box.

## Why not a binary distribution channel?

`unison-blob.o` is a build artifact, not a runtime artifact —
end users never see it because it's linked into `unison-ui-mac.app`
at build time. The full `.app` is the right thing to distribute via
GitHub Releases (and is the planned path; see TODO.md). The vendored
object here is for the build-from-source workflow.
