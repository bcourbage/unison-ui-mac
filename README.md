# Unison-UI-Mac

[![CI](https://github.com/bcourbage/unison-ui-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/bcourbage/unison-ui-mac/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/bcourbage/unison-ui-mac?label=release)](https://github.com/bcourbage/unison-ui-mac/releases)
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)
[![Platform: macOS 15+](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey.svg)](https://www.apple.com/macos/)
[![Arch: arm64](https://img.shields.io/badge/arch-arm64-orange.svg)](#system-requirements)
[![Embeds Unison 2.54.0](https://img.shields.io/badge/Unison-2.54.0-success.svg)](https://github.com/bcpierce00/unison/releases/tag/v2.54.0)

A native macOS GUI for the [Unison File Synchronizer](https://github.com/bcpierce00/unison),
written in Swift + AppKit. Personal project; deliberately not for upstream
contribution (see [NOTICE.md](NOTICE.md) for the license and attribution
trail, and [CONTRIBUTING.md](CONTRIBUTING.md) for the rules of engagement
on this fork).

> 📦 **To install:** see [INSTALL.md](INSTALL.md). Prebuilt `.app`
> downloads (when available) are on the
> [Releases page](https://github.com/bcourbage/unison-ui-mac/releases);
> first-run Gatekeeper notes are in
> [INSTALL.md § Gatekeeper](INSTALL.md#first-launch--gatekeeper).
>
> 📖 **For a feature-by-feature user guide, see [MANUAL.md](MANUAL.md).**
> 📝 **Release history:** [CHANGELOG.md](CHANGELOG.md).

## What this is

Upstream Unison ships a Cocoa UI under `src/uimac/` that predates ARC,
Swift, and modern AppKit patterns. This is a fresh-start re-implementation
of the same job — same OCaml callback protocol (`uimacbridge`), same
workflow — written in Swift 6 / AppKit, programmatic UI, XcodeGen-driven
project, no `.xib` files. **It embeds Unison's compiled OCaml core**
(`unison-blob.o`) into the app bundle, so installing the `unison` CLI on
this machine is *not* required for the app to run.

### Unison version

This project embeds upstream Unison at **v2.54.0** (commit `745dccd`,
which is 11 commits past the `v2.54.0` tag on `master`). The
`MAJORVERSION=2.54` value is significant: an SSH peer running a different
major version will be flagged by the in-app version-mismatch check
(`VersionCheck.swift`) on profile open. The Unison wire protocol
guarantees compatibility within a major version only.

The OCaml core lives as a prebuilt object file under
[`vendor/`](vendor/) — see [vendor/README.md](vendor/README.md) for
provenance (upstream commit hash, SHA-256, applied patches) and the
rebuild recipe (`make vendor-blob`). The vendored blob means everyday
builds skip the 5–10 min OCaml compile entirely. When upstream cuts
a new release, the maintainer runs `make vendor-blob` against an
updated upstream checkout to refresh it.

### Remote-side requirement (SSH profiles)

For `ssh://` profiles, the *remote* machine still needs the `unison` CLI
installed because `ssh://` profiles spawn `unison -server` on the far
side. Pure local-to-local profiles (two local directories) have no
external dependency.

The remote `unison` must be the **same major version** (2.54.x) as this
app's embedded copy. Common ways to install it on the remote:

- **macOS**: `brew install unison`
- **Debian/Ubuntu**: `sudo apt install unison`
- **Other**: upstream install instructions at
  <https://github.com/bcpierce00/unison/wiki/Downloading-Unison>

Source / source-build: <https://github.com/bcpierce00/unison>.

## Status

Functional for the day-to-day sync workflow, with a feature set that goes
beyond what the legacy uimac app offered in several places. Highlights:

- **Profile management**: profile picker (launch view) + a dedicated
  Profile Editor manager window with drag-reorder, hide/unhide (UI-only),
  duplicate, delete-to-Trash, and a form editor that surfaces `ignore` and
  `ignorenot` as first-class fields (the legacy app only had a raw `.prf`
  text view).
- **Reconcile UI**: Finder-style outline view with three configurable
  layout modes (flat / nested-collapsed / nested-full, mirroring
  upstream Unison's "Switch table nesting") + three expand policies
  (smart / all / root-only), color-coded Action column with the user's
  decision visible (forced / skipped / merged badges that hide the
  underlying arrow), status icons in First and Second columns
  (Created / Modified / Deleted / PropsChanged), folder aggregates,
  details footer, ⚠ failure markers with hover-for-reason, tooltips on
  truncated paths, multi-line status disclosure for SSH errors.
- **Per-row actions**: direction overrides (→ Second / ← First / Skip /
  Merge), force older / force newer (mtime-based), ignore-pattern shortcuts
  (Ignore Path / Extension / Name), and inline Diff viewer (unified-diff
  format with green/red/blue per-line coloring).
- **Selection helpers**: Select Conflicts, Revert to Unison's Recommendation.
- **Archive recovery**: reactive (one-click "delete orphans and retry"
  during reconcile fatals) and proactive (`Reset Archives…` in the Profile
  Editor).
- **286 unit tests** in ~1 s via `make test`. Pure-logic modules
  (`ReconcileTree`, `ArchiveHash`, `ArchiveRecovery`, `ProfileDocument`,
  `ProfilePreferences`, `RowSelectionRules`, `ReconcileSummary`,
  `SettingsModel`, `ArchiveCleanup`, etc.) carry exhaustive coverage;
  AppKit view-controllers are verified by interactive testing rather
  than XCTest.

See [TODO.md](TODO.md) for the full prioritized status and what's still
open (mostly P3 hygiene items at this point).

## Build and install

For end-to-end install steps (Xcode/Homebrew prereqs, building, ad-hoc
signing, copying to `/Applications`), see **[INSTALL.md](INSTALL.md)**.

For day-to-day development, the Makefile targets are:

```sh
make build      # Debug build by default. Strips libasmrun's main.n.o,
                # regenerates xcodeproj, runs xcodebuild. Links against
                # the vendored unison-blob.o in vendor/. Pass
                # CONFIG=Release for an optimized build.
make install    # Release build + sign + copy to /Applications
                # (always Release, regardless of CONFIG)
make vendor-blob   # Maintainer-only — rebuild vendor/unison-blob-*.o
                #  from an upstream Unison checkout (needs ../unison/)
make run        # build + launch the binary directly (stderr → terminal)
make app        # build + `open`s the .app (detached, no terminal output)
make test       # XCTest bundle — always uses Debug
make open       # opens unison-ui-mac.xcodeproj in Xcode
make clean      # cleans .build/; preserves xcodeproj
make distclean  # also removes the generated xcodeproj
make print-config  # show resolved paths
```

The build links against `vendor/unison-blob-2.54.0-arm64.o`, a
prebuilt OCaml object committed to this repo. No upstream Unison
clone is required for `make build` / `make install`. Builds finish
in a few seconds rather than the 5–10 min that an OCaml-from-source
build would take. Override the blob path on the command line if you
want to test a custom build:
`make build BLOB=/path/to/your/unison-blob.o`.

### Local fork patches

This project applies a small set of patches to the upstream Unison
source — currently just one, registering an `abortAll` callback so
the GUI's Stop button can do a real mid-sync abort. Patch files live
in [`patches/`](patches/). They're already baked into the vendored
`unison-blob.o`; you only need to re-apply them if you're rebuilding
the blob from an upstream clone (`make vendor-blob` does this
automatically as a prereq). Patches stay LOCAL — never proposed back
to bcpierce00/unison, per this project's LLM-usage posture (see
[NOTICE.md](NOTICE.md)).

## How it works (architecture sketch)

```
+------------------+         +-------------------+        +----------------+
|   Swift / AppKit |  msg →  |   C bridge        |  msg → |   OCaml worker |
| (@MainActor)     |  ←────  |   (UnisonBridgeC) |  ←──── | (uimacbridge)  |
+------------------+         +-------------------+        +----------------+
        ▲                              │
        │ trampolines                  │ pthread mutex+condvar
        │ + DispatchQueue.main.async   │ caml_acquire/release_runtime_system
```

- **Swift→OCaml** synchronous calls go through a single-slot request /
  response handoff to a dedicated OCaml worker thread. The worker acquires
  the OCaml runtime lock, runs the requested callback, signals completion
  on a condvar.
- **OCaml→Swift** callbacks (status, progress, init1/2 complete, per-row
  reload, sync complete, diff, warn, fatal) run inside `CAMLprim` functions
  on the OCaml thread; the Swift trampoline copies any strings
  synchronously then `dispatch_async`s the user handler to the main queue.
- **Modal warn/error** alerts use the condvar dance in reverse — the OCaml
  worker releases the runtime, blocks waiting for a response, gets woken by
  `unison_bridge_warn_response` / `_fatal_response` after Swift's
  `NSAlert.runModal()` returns.

Per-row OCaml `stateItem` values are kept alive across calls via
`caml_register_generational_global_root`, indexed the same way as the
Swift `[StateItem]` array — Swift row `i` maps to OCaml `g_ri_roots[i]`.

See [unison/src/uimacbridge.ml](https://github.com/bcpierce00/unison/blob/master/src/uimacbridge.ml)
for the full OCaml-side protocol.

## Project layout

```
unison-ui-mac/
├── project.yml                          XcodeGen project definition
├── Makefile                             Build orchestration
├── README.md                            This file (orientation + dev build)
├── INSTALL.md                           End-user install guide
├── install.sh                           One-shot installer (sign + /Applications + de-quarantine)
├── MANUAL.md                            Full user manual (feature guide)
├── NOTICE.md                            Attribution and license details
├── CONTRIBUTING.md                      Contribution policy + LLM-usage disclosure
├── LICENSE                              GPLv3 (full text)
├── TODO.md                              Outstanding work / done items by tier
├── vendor/                              Prebuilt unison-blob.o + provenance
├── patches/                             Local fork patches against upstream Unison
├── Sources/
│   ├── App/                             Swift + AppKit
│   │   ├── main.swift                   NSApplicationMain bootstrap
│   │   ├── AppDelegate.swift            Lifecycle, handler installation, menus
│   │   ├── MainMenu.swift               Programmatic menu bar (Edit, Action, …)
│   │   ├── ProfileWindowController.swift   The picker — launch view
│   │   ├── ProfileEditorWindowController.swift  Multi-profile manager window
│   │   ├── ProfileFormWindowController.swift    Single-profile content editor
│   │   ├── ProfileDocument.swift        .prf parser / serializer (pure Swift)
│   │   ├── ProfilePreferences.swift     UserDefaults: hide + custom order
│   │   ├── ReconcileWindowController.swift  Outline view + sync UI
│   │   ├── ReconcileToolbar.swift       Toolbar + DirectionAction enum
│   │   ├── ReconcileTree.swift          Tree model + FolderAggregate + RowOverride
│   │   ├── PathCellView.swift           Finder-style folder/file icon + name + tooltip
│   │   ├── StatusIconCellView.swift     First/Second status SF Symbols
│   │   ├── ProgressCellView.swift       Custom-drawn per-row progress bar
│   │   ├── DiffWindowController.swift   Unified-diff viewer
│   │   ├── DirectionAction.swift        (in ReconcileToolbar) per-row direction enum
│   │   ├── IgnoreAction.swift           Ignore Path/Ext/Name enum + menu wiring
│   │   ├── RowSelectionRules.swift      Select Conflicts / Revert pure logic
│   │   ├── ArchiveHash.swift            Pure-Swift port of Update.archiveHash
│   │   ├── ArchiveCleanup.swift         Trash archive files for a hash
│   │   ├── ArchiveRecovery.swift        Reactive recovery for inconsistent state
│   │   ├── PasswordSheet.swift          SSH credential prompts
│   │   ├── StateItem.swift              Swift mirror of OCaml's stateItem
│   │   ├── UnisonBridge.swift           Handler registry + Swift trampolines
│   │   └── TraceLog.swift               os.Logger wrapper (subsystem net.courbage.unison-ui-mac)
│   └── Bridge/
│       ├── UnisonBridgeC.h              C public API
│       └── UnisonBridgeC.c              OCaml↔C glue + thread machinery
├── Tests/                               XCTest bundle (286 tests, ~1 s)
└── Resources/
    ├── Info.plist                       App bundle metadata
    └── AppIcon.icns                     From upstream uimac
```

## License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE) for the
full text and [NOTICE.md](NOTICE.md) for attribution to the upstream Unison
project. This project embeds Unison's compiled object code; as a combined
work it falls under the same license.

## Credits

The application icon and the entire OCaml synchronization engine come from
the upstream [Unison File Synchronizer](https://github.com/bcpierce00/unison),
copyright © 1999– Benjamin C. Pierce and contributors. The original Cocoa
UI by Trevor Jim, Craig Federighi, Ben Willmore and others established the
bridge protocol this project follows.

This project was built with substantial LLM assistance and is therefore
**deliberately not** for upstream contribution — see Unison's CONTRIBUTING.md
LLM-usage policy. The compatible-license + downstream-only positioning is
spelled out in [NOTICE.md](NOTICE.md).
