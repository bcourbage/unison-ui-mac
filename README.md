# unison-ui-mac

A native macOS GUI for the [Unison File Synchronizer](https://github.com/bcpierce00/unison),
written in Swift + AppKit. Personal project; not intended for upstream
contribution (see [NOTICE.md](NOTICE.md) for the license / attribution
details and the reason).

## What this is

The upstream Unison project ships a Cocoa UI under `src/uimac/`. That UI
predates ARC, predates Swift, and uses Interface Builder + Objective-C
patterns from the early 2010s. This project is a fresh take on the same
job: same OCaml callback protocol (`uimacbridge`), same workflow, but
written in modern Swift 6 / AppKit, programmatic UI, XcodeGen-driven
project, no `.xib` files.

## Status

Functional for the day-to-day sync workflow:
- Pick a profile from the `~/Library/Application Support/Unison/` directory
- Reconcile with proper credential prompts for SSH profiles
- Finder-style outline view with default-expanded folders, native blue
  folder icons, color-coded Action column per direction
- Status icons in Local + Remote columns (Created / Modified / Deleted /
  PropsChanged / Unchanged)
- Folder aggregate: the Action column on folders shows the unified
  direction when every descendant agrees
- Details footer with `unisonRiToDetails`
- Direction overrides (Local / Remote / Skip / Merge) with multi-row
  + folder-level apply
- Rescan, Profiles (back-to-picker), and soft-Cancel in the toolbar
- Synchronize with per-row progress + global progress bar
- Modal warning + fatal-error sheets, with a one-click "Delete N Orphan
  Archive(s) and Retry" recovery for Unison's inconsistent-state failure
- Window-close guard during sync
- 53 unit tests via `make test`

See [TODO.md](TODO.md) for what's still missing (ignore actions, diff
viewer, new-profile editor, full menu mirror, force-older/newer,
hide/delete profile, etc.).

## Build prerequisites

- macOS 15 or later (developed on macOS Tahoe 26)
- Xcode 26 (older versions probably work; not tested)
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
make run        # builds + launches the binary directly (stderr -> terminal)
make app        # builds + `open`s the .app (detached, no terminal output)
make test       # runs the XCTest bundle (`unison-ui-macTests`)
make open       # opens unison-ui-mac.xcodeproj in Xcode
make clean      # cleans .build/; preserves xcodeproj
make distclean  # also removes the generated xcodeproj
make print-config  # show resolved paths
```

The first build is slow because it builds the entire Unison OCaml core
(`make macui` in the upstream tree, which produces the embeddable
`unison-blob.o`). Subsequent builds are fast — only Swift/C changes recompile.

## How it works (very short version)

```
+------------------+         +-------------------+        +----------------+
|   Swift / AppKit |  msg →  |   C bridge        |  msg → |   OCaml worker |
| (@MainActor)     |  ←────  |   (UnisonBridgeC) |  ←──── | (uimacbridge)  |
+------------------+         +-------------------+        +----------------+
        ▲                              │
        │ trampolines                  │ pthread mutex+condvar
        │ + DispatchQueue.main.async   │ caml_acquire/release_runtime_system
```

- **Swift→OCaml** synchronous calls dispatch through a request/response
  slot to a dedicated OCaml worker thread; that worker acquires the OCaml
  runtime lock, runs the requested callback, signals completion.
- **OCaml→Swift** callbacks (status, progress, init1/2 complete, per-row
  reload, sync complete) run inside `CAMLprim` functions on the OCaml
  thread; the Swift trampoline copies any strings synchronously and then
  `dispatch_async`s the user handler to the main queue.
- **Modal warn/error** alerts use the same condvar dance but in reverse:
  the OCaml worker releases the runtime, blocks on a request, and is woken
  by Swift's `unison_bridge_warn_response` / `_fatal_response` after the
  user dismisses an `NSAlert.runModal()`.

Per-row OCaml `stateItem` values are kept alive across calls via
`caml_register_generational_global_root`, indexed the same way as the
Swift `[StateItem]` array — so Swift row 7 maps to OCaml `g_ri_roots[7]`.

See [unison/src/uimacbridge.ml](https://github.com/bcpierce00/unison/blob/master/src/uimacbridge.ml)
for the full OCaml-side protocol.

## Project layout

```
unison-ui-mac/
├── project.yml                          XcodeGen project definition
├── Makefile                             Build orchestration
├── README.md                            This file
├── NOTICE.md                            Attribution and license details
├── LICENSE                              GPLv3 (full text)
├── TODO.md                              Outstanding work
├── Sources/
│   ├── App/                             Swift + AppKit
│   │   ├── main.swift                   NSApplicationMain bootstrap
│   │   ├── AppDelegate.swift            Lifecycle, handler installation, menu actions
│   │   ├── MainMenu.swift               Programmatic main menu bar (incl. Help)
│   │   ├── ProfileWindowController.swift  Profile picker
│   │   ├── ReconcileWindowController.swift  Outline view + sync UI + DirectionVisual
│   │   ├── ReconcileToolbar.swift       Toolbar (Profiles/Rescan/direction group/Go/Stop)
│   │   ├── ReconcileTree.swift          Tree model + FolderAggregate
│   │   ├── PathCellView.swift           Finder-style folder/file icon + name
│   │   ├── StatusIconCellView.swift     Local/Remote status SF Symbols
│   │   ├── ArchiveRecovery.swift        Inconsistent-archive cleanup parser
│   │   ├── PasswordSheet.swift          SSH credential prompts
│   │   ├── StateItem.swift              Swift mirror of OCaml's `stateItem`
│   │   ├── UnisonBridge.swift           Handler registry + Swift trampolines
│   │   └── TraceLog.swift               Dev file logger (/tmp/unison-ui-mac.log)
│   └── Bridge/
│       ├── UnisonBridgeC.h              C public API
│       └── UnisonBridgeC.c              OCaml↔C glue + thread machinery
├── Tests/                               XCTest bundle (53 tests)
│   ├── StateItemTests.swift             Value-type round-trip (3)
│   ├── DirectionActionTests.swift       Toolbar-identifier invariants (4)
│   ├── DirectionVisualTests.swift       glyph/tint mapping incl. user-skip (18)
│   ├── StatusIconDescriptorTests.swift  Status-string → SF symbol mapping (6)
│   ├── ReconcileTreeTests.swift         Tree + FolderAggregate (11)
│   ├── ArchiveRecoveryTests.swift       Inconsistent-archive parser (5)
│   ├── TraceLogTests.swift              Async writer + concurrent safety (2)
│   └── BridgeTests.swift                Live OCaml bridge + perf measure (4)
└── Resources/
    ├── Info.plist                       App bundle metadata
    └── AppIcon.icns                     From upstream uimac
```

## License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE) for the
full text and [NOTICE.md](NOTICE.md) for attribution to the upstream
Unison project. This project embeds Unison's compiled object code; as a
combined work it falls under the same license.

## Credits

The application icon and the entire OCaml synchronization engine come
from the upstream [Unison File Synchronizer](https://github.com/bcpierce00/unison),
copyright © 1999– Benjamin C. Pierce and contributors. The original Cocoa
UI by Trevor Jim, Craig Federighi, Ben Willmore and others established
the bridge protocol this project follows.
