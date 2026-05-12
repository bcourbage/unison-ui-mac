# NOTICE — Attribution and Licensing

## Derivation

This project, **unison-ui-mac**, is a native macOS user interface for the
**Unison File Synchronizer** by Benjamin C. Pierce and contributors.

- Upstream project: <https://github.com/bcpierce00/unison>
- Upstream documentation: <https://github.com/bcpierce00/unison/wiki>
- License: GNU General Public License version 3 (or later)

The application embeds Unison's compiled OCaml code (`src/unison-blob.o`,
produced by the upstream Unison build) and calls into it through the
callback bridge declared in [src/uimacbridge.ml](https://github.com/bcpierce00/unison/blob/master/src/uimacbridge.ml).
As such, **this project is a "modified version" of Unison for GPLv3
purposes** and is distributed under the same license. See [LICENSE](LICENSE).

## What is original to this project

- The Swift application code under `Sources/App/`
- The C bridge (`Sources/Bridge/UnisonBridgeC.{c,h}`) — newly written;
  inspired by the layout of the original Objective-C bridge at
  [src/uimac/Bridge.m](https://github.com/bcpierce00/unison/blob/master/src/uimac/Bridge.m)
  but rewritten from scratch using OCaml 5's `caml_acquire_runtime_system` /
  `caml_release_runtime_system` API and generational global roots.
- The XcodeGen project definition (`project.yml`), the Makefile build
  orchestration, and the application Info.plist.

## What is taken or derived from the upstream Unison project

- The application icon (`Resources/AppIcon.icns`) is copied verbatim from
  [src/uimac/Unison.icns](https://github.com/bcpierce00/unison/blob/master/src/uimac/Unison.icns).
- The full set of OCaml callback names and semantics
  (`unisonGetVersion`, `unisonInit0/1/2`, `unisonRiSet*`, etc.) are part of
  the public interface of Unison's `uimacbridge` module and used as
  documented.
- The "preconnection / openConnectionPrompt-Reply-End" credential loop and
  the per-row direction-override semantics follow the protocol defined by
  `src/uimacbridge.ml` and `src/uimac/MyController.m`.

## Required statement under GPLv3 §5

If you redistribute this software (modified or unmodified):
- Keep this NOTICE file and the [LICENSE](LICENSE) file alongside the
  distribution.
- Make the **complete corresponding source code** available, including any
  modifications to the upstream Unison code (none in this repository — we
  link against an unmodified upstream build).
- Disclose the Unison version this build was linked against. Run
  `make print-config` or check the "About" panel in the running app.

## Compatibility note

Unison's own [CONTRIBUTING document](https://github.com/bcpierce00/unison/blob/master/CONTRIBUTING.md)
states that LLM-generated code is unwelcome upstream. **This UI project was
written with substantial LLM assistance and is therefore intentionally NOT
proposed for inclusion in the upstream Unison repository.** It exists as a
separate downstream work.

## Acknowledgments

- **Benjamin C. Pierce** and the Unison contributors for ~25 years of
  maintaining one of the best file-synchronizers ever written.
- **Trevor Jim, Craig Federighi, Ben Willmore** and others who built the
  original Cocoa UI for Unison — the protocol and patterns this project
  follows owe everything to that work.
