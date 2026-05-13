# unison-ui-mac

A native macOS GUI for the [Unison File Synchronizer](https://github.com/bcpierce00/unison),
written in Swift + AppKit. Personal project; deliberately not for upstream
contribution (see [NOTICE.md](NOTICE.md) for the license and attribution,
and the reasoning).

> 📖 **For a feature-by-feature user guide, see [MANUAL.md](MANUAL.md).**

## What this is

Upstream Unison ships a Cocoa UI under `src/uimac/` that predates ARC,
Swift, and modern AppKit patterns. This is a fresh-start re-implementation
of the same job — same OCaml callback protocol (`uimacbridge`), same
workflow — written in Swift 6 / AppKit, programmatic UI, XcodeGen-driven
project, no `.xib` files. **It embeds Unison's compiled OCaml core**
(`unison-blob.o`) into the app bundle, so installing the `unison` CLI on
this machine is *not* required for the app to run.

(For SSH-based profiles, the *remote* machine still needs Unison installed
because `ssh://` profiles spawn `unison -server` on the far side. Pure
local-to-local profiles have no external dependency.)

## Status

Functional for the day-to-day sync workflow, with a feature set that goes
beyond what the legacy uimac app offered in several places. Highlights:

- **Profile management**: profile picker (launch view) + a dedicated
  Profile Editor manager window with drag-reorder, hide/unhide (UI-only),
  duplicate, delete-to-Trash, and a form editor that surfaces `ignore` and
  `ignorenot` as first-class fields (the legacy app only had a raw `.prf`
  text view).
- **Reconcile UI**: Finder-style outline view, default-expanded folders,
  color-coded Action column with the user's decision visible (forced /
  skipped / merged badges that hide the underlying arrow), status icons
  in First and Second columns (Created / Modified / Deleted / PropsChanged),
  folder aggregates, details footer, FAILED highlighting, tooltips on
  truncated paths, multi-line status disclosure for SSH errors.
- **Per-row actions**: direction overrides (→ Second / ← First / Skip /
  Merge), force older / force newer (mtime-based), ignore-pattern shortcuts
  (Ignore Path / Extension / Name), and inline Diff viewer (unified-diff
  format with green/red/blue per-line coloring).
- **Selection helpers**: Select Conflicts, Revert to Unison's Recommendation.
- **Archive recovery**: reactive (one-click "delete orphans and retry"
  during reconcile fatals) and proactive (`Reset Archives…` in the Profile
  Editor).
- **177 unit tests** in ~0.6 s via `make test`.

See [TODO.md](TODO.md) for the full prioritized status and what's still
open (mostly P3 hygiene items at this point).

## Build prerequisites

- macOS 15 or later (developed on macOS Tahoe 26)
- Xcode 26 (older versions may work; not tested)
- Homebrew with:
  - `ocaml` (5.x — tested against 5.4.1)
  - `xcodegen`
- A local clone of the upstream Unison source at `../unison/`
  (or set `UNISON_SRC` in the environment to point elsewhere)

```sh
brew install ocaml xcodegen
```

## Build

```sh
make build      # builds unison-blob.o (via upstream Unison make), strips
                # libasmrun's main.n.o, regenerates xcodeproj, runs xcodebuild
make run        # builds + launches the binary directly (stderr → terminal)
make app        # builds + `open`s the .app (detached, no terminal output)
make test       # runs the XCTest bundle
make open       # opens unison-ui-mac.xcodeproj in Xcode
make clean      # cleans .build/; preserves xcodeproj
make distclean  # also removes the generated xcodeproj
make print-config  # show resolved paths
```

The first build is slow because it builds the entire Unison OCaml core
(`make macui` in the upstream tree, producing the embeddable
`unison-blob.o`). Subsequent builds only recompile changed Swift/C.

### Local fork patches

This project applies a small set of patches to the upstream Unison
source under `$UNISON_SRC` — currently just one, registering an
`abortAll` callback so the GUI's Stop button can do a real mid-sync
abort. Patch files live in `patches/`; `make apply-patches` runs
automatically as a prereq of `make blob` and is idempotent (grep
detects "already applied" and skips). Patches stay LOCAL — never
proposed back to bcpierce00/unison, per this project's LLM-usage
posture (see [NOTICE.md](NOTICE.md)).

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
├── README.md                            This file (orientation + build)
├── MANUAL.md                            Full user manual (feature guide)
├── NOTICE.md                            Attribution and license details
├── LICENSE                              GPLv3 (full text)
├── TODO.md                              Outstanding work / done items by tier
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
│   │   └── TraceLog.swift               Dev file logger (/tmp/unison-ui-mac.log)
│   └── Bridge/
│       ├── UnisonBridgeC.h              C public API
│       └── UnisonBridgeC.c              OCaml↔C glue + thread machinery
├── Tests/                               XCTest bundle (177 tests, ~0.6 s)
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
