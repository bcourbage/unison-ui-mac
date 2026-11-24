# Signed launch and TCC probe

Standalone experimental bundle for the engine-process design. It does not enter the
product build. The parent uses AppKit; the same executable starts a headless engine
role through posix_spawn and an inherited AF_UNIX socket pair. A separate signed
lifeline owns one disposable shell/sleep transport. There is no OCaml runtime here.

The parent makes the status writer nonblocking before copying it. The engine's C
monitor observes GUI-channel closure independently of its directory probe. A nonce
binds the reply to the spawned engine. Successful cleanup requires engine reaping,
valid S/D matching and status EOF. This is a launch/TCC experiment, not the final
codec, complete supervisor or production-ready lifeline.

`lifeline.c` derives from the retained child-reset experiment, with the writer-flag
change removed because the channel creator now owns that setup. It retains known
unqualified setup/error and membership-enumeration paths. Do not substitute it for
the product reaper or treat the ordinary-termination checks as crash qualification.

## Build

Use a Developer ID Application identity and a new artifact directory:

```sh
python3 build.py --identity '<Developer ID Application identity>' --output '<new directory>'
```

The script signs the helper and bundle explicitly with hardened runtime and a secure
timestamp, verifies the result, and records binary/source hashes and minimum OS.
Captured tool output, including verification diagnostics, is bundle-relative. It
uses a separate bundle ID, refuses an existing output bundle, and never invokes
notarization, publishing or the product release pipeline.

## Disposable smoke controls

```sh
python3 run-smoke.py --app '<artifact>/Unison Engine Launch Spike.app' --output '<results>'
```

This creates only private temporary fixtures, launches through LaunchServices,
checks parent/child reads plus an ENOENT control, and requires verified cleanup.
It repeats three times by default. The app exits when the result is saved.

## Protected-path pass

Obtain permission for the exact real targets and probe-only grant changes first.
Use a private configuration outside the repository with this shape:

```json
{
  "scenario": "protected-access",
  "keep_open": false,
  "output": "/private/tmp/your-private-fixture/result.json",
  "targets": [
    {"label": "approved-directory", "path": "/approved/directory"}
  ]
}
```

Launch with `open -n '<app>' --args --config '<private config>'`. The child probes
first, then the parent. The operation is lstat, read-only open and one readdir;
entry names and content are discarded. A file target instead reads and discards
one byte, so use only approved files or disposable fixtures. Do not add arbitrary
real files merely to test this mode.

Record the fresh denied state, add only this signed bundle to Full Disk Access in
System Settings, authenticate locally if requested, repeat after granting and on
another launch, then switch only the probe off and repeat denial. Remove the probe
entry afterwards. Do not reset TCC globally or edit its database. Existing Unison
and other app grants must remain unchanged.

Keep raw configs/results private; retained evidence uses target labels and a bundle-
relative executable path. To qualify attribution, correlate tccd responsible/accessing
PIDs with the probe's recorded parent and engine PIDs, without retaining raw paths.

No integrated Unison scan, file transfer, Photos-framework prompt, authenticated SSH,
notarization or macOS 15 result is implied by this experiment.

## Production packaging follow-up

The measured helper used signing identifier `lifeline`. Production packaging must
set an explicit reverse-DNS identifier with `codesign --identifier`, for example
`net.courbage.unison-ui-mac.lifeline`, and verify it in the signed inventory,
designated requirement, notarization and crash attribution. The experiment does not
qualify that future packaging. Do not rewrite the old inspection to imply it did.

The evidence's `build-used.py` is the original tested builder snapshot, not the
current build entry point. It is retained to resolve the source hash even after
output-presentation corrections to this directory's `build.py`.
