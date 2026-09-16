# #176 implementation and validation

## Cause and scope

On the local Xcode toolchain, `xcodebuild -showBuildSettings` for the unmodified
Release configuration reports `ENABLE_CODE_COVERAGE = YES`. The project did not
set a Release override. Release now explicitly sets it to NO at project scope,
covering both the Swift app and the C launcher; Debug remains unchanged. Test
build logs still contain Swift `-profile-generate` instrumentation.

The finished-bundle gate checks every regular Mach-O (including all architecture
slices inspected by otool/nm), not just a build setting. It rejects coverage
sections and counters even after symbol stripping, and fails closed for missing
main/launcher executables, malformed binaries and inspection-tool errors.
Release build, macOS-15 smoke, signing/package, and promotion paths run the gate.
Signed packaging and promotion also run the CLI/client/server smoke with coverage
output redirection unset and a disposable working directory. They never rebuild
or re-sign the tested RC during promotion.

## Manual clarification

The premise that v0.10.0 bundled an old copy of this app's manual was incorrect:
`openUiMacHelp` opened GitHub's main-branch MANUAL.md. Only the separate upstream
Unison reference manual was bundled. This change adds `Resources/UIManual.html`
and routes app Help to that local resource. It is generated from the corrected
MANUAL.md already merged in #175. CI checks exact regeneration with the existing
hash-pinned Markdown dependency; the release gates check the exact resource and
its source hash inside the app. The upstream reference manual is unchanged.

## Local evidence (2026-09-15)

These are local build checks, **not signed/notarized RC acceptance**.

- The installed 0.10.0 app is rejected by `verify-no-coverage.py` at its cltool.
  Its cltool SHA-256 is
  `31daedcf841857dd63e075d88fdf69104a3a45b344c753d9b1e31b7a2302f8c4`.
- `python3 scripts/test-verify-no-coverage.py`: real Clang fixtures pass the clean
  case and reject an instrumented main, stripped instrumented main, instrumented
  launcher, nested helper, missing launcher and malformed Mach-O.
- Local Release build passes the gate over seven Mach-O files. All CLI smoke
  cases pass, including a 200 KB client/server transfer, invalid option, and server
  EOF. No raw coverage file is produced with `LLVM_PROFILE_FILE` unset.
- `make -o verify-runtime-minos test`: 1,459 tests, one skip, zero failures.
  The explicit local-only prerequisite bypass is necessary because this Mac's
  Homebrew OCaml runtime has minos 26.0. The local build is **not** evidence for
  macOS-15 compatibility; CI and release still enforce the original floor without
  any bypass and reject newer-runtime linker warnings.
- The exact bundled HTML passes `verify-bundled-manual.py`; a deliberately stale
  resource fails. Regeneration `--check` and site tests/build pass. All local
  fragment references in the generated offline manual resolve.
- `actionlint -shellcheck=` passes. Full actionlint reports existing shellcheck
  findings at the unchanged opam-PATH and notarization commands.
- A fresh HTTP read of Home, Install, FAQ, Manual and Credits checked 36 local
  fragment links, including `#the-unison-command`. Specific live text checks passed
  for the 120-second deadline, Continue in Background, and additive Pictures plus
  Documents scope. These are content/anchor checks, not a stale-phrase-only scan.

## Still required for v0.10.1

Keep #176 open until the ordinary release process produces a signed RC. Record
its revision and full archive SHA-256; run the gates and CLI/server checks on that
exact artifact, and open the bundled manual through Help to verify presentation.
The PR does not bump the version, tag, merge, sign, approve a release environment,
or publish. Publication must promote the same accepted RC bytes.
