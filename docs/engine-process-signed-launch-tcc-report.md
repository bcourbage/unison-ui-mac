# Signed launch and TCC: first platform pass

November 23, 2026. **Passed within the scope below; step B is not complete.**

PR #242 was squash-merged as `db739ff843a2191acd9d5604bc8fdd28b6ff8f2b` after both
checks passed on `bf8e587`. Local main is current. The spike branch then merged main
as `05e994c`; the standalone probe sources are identified by hashes
in the [build inspection](evidence/engine-process-spike-2026-11-23/signed-launch/build-inspection.json).
Production source and the installed app were not changed.

## Topology and artifact

The separate `Unison Engine Launch Spike.app` uses bundle identifier
`net.courbage.unison-ui-mac.engine-launch-spike` and Developer ID Application team
`QJXKM5Q4WH`. Both executable components have hardened runtime, a secure timestamp
and minimum macOS 15.0. Strict signature verification passed. The artifact has not
been notarized and has no stapled ticket. The tested helper's signing identifier is
`lifeline`; it is not a qualified production identifier.

The AppKit GUI and headless engine use the same signed executable. The GUI launches
its engine with posix_spawn, an inherited Unix socket pair and a status writer it
already made nonblocking. A C monitor watches GUI-channel closure independently of
the engine's filesystem operation. The engine launches the signed lifeline, which
starts a disposable shell/sleep transport; a readiness byte prevents the fixture
from retiring the helper before transport startup.

The GUI drains status separately and verifies the nonce-bound engine identity,
engine reaping, matched S/D records and EOF. The helper is retired with SIGTERM,
not SIGKILL. This pass tests the selected launch relationships but uses a Foundation
filesystem stub instead of OCaml, no real SSH, and a prototype helper with remaining
setup/error/enumeration work. It is not production integration qualification.

Sources, build instructions and scope are under
[spikes/engine-process/launch-tcc](../spikes/engine-process/launch-tcc/README.md).

## Observed results on Heracles

Platform: arm64, macOS 27.2.1 (26B131), Apple clang 21.0.0. Every launch used
LaunchServices (`open -n`) rather than directly running the binary from Terminal.

| Check | Result |
|---|---|
| Disposable directory, file and missing-path control | Initial smoke passed, followed by three asserted repeats. Parent/engine agreed; the missing path returned ENOENT. |
| Signed helper and engine lifecycle | All smoke and protected runs reaped the engine and helper, preserved transport signal 15 and completed S/D+EOF. |
| Fresh probe identity, no FDA entry | Parent and engine both got EPERM for Photos-library and Mail directory opens. No permission dialog was observed; the app completed promptly. |
| FDA newly granted to probe only | Both roles opened/read one directory entry on both targets. |
| Relaunch with that existing grant | Both roles again succeeded, on unchanged signed bytes. |
| Probe FDA explicitly switched off | Both roles again got EPERM on both targets, with normal cleanup. |
| Cleanup of privacy setting | Probe entry removed and verified absent in System Settings. Installed Unison's existing FDA switch stayed on. |

The three retained smoke repeats took 0.147, 0.109 and 0.133 seconds inside the
parent worker. This excludes LaunchServices/app startup and is not a scan, IPC-load
or performance acceptance measurement.

The user explicitly authorized read-only access to the real Photos-library and
Mail directories plus probe-only grant tests. The user authenticated the OS sheet
locally. Only directory metadata/access was tested: lstat, open and one readdir.
Names and file contents were not retained. No Photos library, mail data, profile,
archive, shell configuration or existing privacy grant was changed.

## TCC attribution

TCC logs independently corroborate the parent/child relationship. For the granted
run they identify GUI PID 22460 as responsible and engine PID 22462 as accessing;
the responsible identifier is the probe, not Terminal or Codex. The AllFiles request
is recorded as Allowed (System Set). For the revoked run, GUI 22552 is responsible
for engine 22554 and AllFiles is Denied (System Set).

This supports the selected same-executable child topology under the GUI's FDA grant
on this machine. It does not establish all services or supported OS versions. No
separate Photos-framework consent flow was requested or qualified.

Retained [attribution evidence](evidence/engine-process-spike-2026-11-23/signed-launch/tcc-attribution.json)
contains identifiers, PIDs, timestamps, service and authorization outcomes only. Raw
TCC messages were temporary and were removed after extraction. No global TCC reset
or database editing was used. The [privacy-state record](evidence/engine-process-spike-2026-11-23/signed-launch/privacy-state-record.json)
records the UI-observed grant/revoke/removal sequence.

## SIGPIPE parity and portable evidence

Independently checked `src/remote.ml:31–33` at vendored base
`91421d0617b0fb543c0eee51bcb4d4791d8b0631`: Unix startup ignores SIGPIPE for the
engine process. The PTY spawn path executes the transport without a SIGPIPE reset.
This supports preserving the inherited disposition, rather than forcing default.
The [source record](evidence/engine-process-spike-2026-11-23/sigpipe-source.json)
is immutable-source evidence, not an additional runtime test.

Two diagnostic strings were made portable before pushing: the signature-verification
output is now bundle-relative, and the failed early-stop traceback uses the evidence-
relative script name. Outcomes and component hashes are unchanged. Original evidence
hashes and the transformations are recorded in `evidence-redactions.json`.

The current `build.py` now strips the artifact directory from all captured tool
output, including verification diagnostics. It was not used to rebuild or re-sign
the tested bundle. Its original tested version is preserved byte-for-byte as
`build-used.py` next to the inspection; the inspection's original source hash still
matches that snapshot. Use the current builder for new artifacts.

## Evidence and remaining work

Path-free run results and signing inspection are under
[signed-launch](evidence/engine-process-spike-2026-11-23/signed-launch/build-inspection.json).
The initial one-off smoke result was checked and its private temporary fixture was
removed; the three repeats and four protected-state results are retained. The sources and their hashes
are preserved separately from compiled artifacts. No completed probe PIDs remained
when checked; no process-name kill was used.

Still required before step B can pass:

- Actual Unison/OCaml integration, all spawn/reaper paths and the real prompt reader.
- Signed failure injection for engine/GUI/helper death, checked startup/PTY handshakes,
  bounded group enumeration, status/lifecycle backpressure and reconnect barriers.
- Actual transport-exit evidence and #35 prompt/exit ordering under authenticated SSH.
- Production helper signing with an explicit reverse-DNS identifier, for example
  `codesign --identifier net.courbage.unison-ui-mac.lifeline`. Verify the identifier
  and designated requirement in packaging inspection, notarization/crash attribution
  and any future identity checks; do not infer this from the probe's plain identifier.
- Notarized installed-bundle behavior, production-identity/existing-grant compatibility,
  macOS 15 and its TCC outcomes. Deployment target 15.0 is not a runtime test.
- Protected file/tree behavior beyond this limited directory-access probe.

The next implementation boundary remains helper/error-path completion and actual
transport/prompt integration. These results remove one current-machine topology
uncertainty; they do not approve the production cutover or concurrency.
