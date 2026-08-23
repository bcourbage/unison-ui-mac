# Release checklist

Steps to validate before tagging a release. The mechanical cut (version bump,
CHANGELOG, `release-notes/<version>.md`, tag → workflow → Homebrew cask bump) is
in the release runbook; this file is the **validation** gate — things that must
be confirmed against the actual built artifact, not just CI.

## Every release

- [ ] `main` is green; the release build (`release.yml`, Release configuration)
      is built from the exact tagged commit.
- [ ] Artifact reports the right `MARKETING_VERSION (CURRENT_PROJECT_VERSION)`,
      minimum macOS, a Developer ID signature with a hardened runtime, a stapled
      notarization ticket, and no Debug/autotest symbols.
- [ ] Vendored blob checksum matches `vendor/README.md`.

## 0.5.1

### First real 0.5.0 → 0.5.1 Sparkle auto-update (TODO #1)
0.5.0 was the first Sparkle build, so there was no prior client to update *from*;
0.5.1 is the first end-to-end exercise of the update path AND the first time
`release.yml` runs the appcast **seed-authentication + build-monotonicity** paths
against a **published** feed (0.5.0 took the first-release 404 path). This is a
real gate, not a formality — do it on a real machine, after tagging.

- [ ] The `v0.5.1` release job authenticated the published `appcast.xml` (feed
      signature) and passed the build-monotonicity check (build **20** > 19),
      rather than taking any first-release/404 path.
- [ ] The published appcast validates: `scripts/verify-appcast.py` (feed +
      the new archive by exact URL) is green in the job, and the served feed is
      byte-identical to the signed one.
- [ ] On a machine running an **installed 0.5.0**: App menu ▸ Check for Updates
      finds 0.5.1, downloads it, verifies the EdDSA signature, and installs it
      through the app (no Gatekeeper prompt on the Sparkle-delivered update).
- [ ] After the update, the About panel shows **0.5.1 (build 20)**.

### Scan-interruption withdrawal — actual-artifact assertions (issues #53 / #94)
Run against the **final signed Release** `.app` binary
(`…/Release/unison-ui-mac.app/Contents/MacOS/unison-ui-mac`):

- [ ] **`signal_scan_transport` and `classify_reap` are ABSENT.**
      `nm <binary> | grep -E 'signal_scan_transport|classify_reap'` → no output.
- [ ] **"Stop Scan" and "Scan stopped" strings are ABSENT.**
      `strings <binary> | grep -E 'Stop Scan|Scan stopped'` → no output.
- [ ] **Shared transport-child registry/reaper symbols are PRESENT.**
      `nm <binary> | grep -E 'transport_child_terminated|reap_transport_children|track_child|retire_child'`
      → all four present (the connect-prompt classifier and shutdown reaping need them).
- [ ] **Scan-phase UI offers only Return to Profiles.** During a running scan the
      toolbar Stop control reads **Return to Profiles** (never "Stop Scan"), and
      invoking it returns to the picker without cancelling the scan (it winds down
      in the background). Cross-check with TC11.
- [ ] **Sync-time Stop still operates normally.** During an actual sync, Stop
      aborts the running transfer via `Abort.all` (unwinds at the next
      checkpoint), unchanged.

### Lifecycle re-runs on the signed Release candidate
Behavior changed around scan-leave (#94) and TC11 was rewritten, so re-run these
against the **final signed RC** (not just a Debug build):

- [ ] **TC9b** (`docs/manual-test-step2b.md`) — pick a profile while a scan is
      running: the new open waits for the abandoned scan, then starts; the first
      profile's connection is closed, not leaked or clobbered.
- [ ] **TC11** (`docs/manual-test-step2b.md`) — post-auth transport wedge during
      a scan: reaches restart-required within the scan timeout; the toolbar shows
      **Return to Profiles** only (no "Stop Scan"); a waiting replacement profile
      is carried to restart-required; quit + reopen recovers cleanly.

## 0.4.2

### App icon — native Icon Composer `.icon` (must build with Xcode 26.6)
The app icon (`Resources/Unison.icon`) needs **Xcode 26's `actool`** to compile
its appearance-aware renditions and the older-macOS `.icns` fallback. The release
pipeline (`release.yml`) runs on the `macos-26` runner and fail-closed pins
**Xcode 26.6**, so it does exercise that compilation path. The PR CI job
(`ci.yml`, `macos-15`) does not, so still confirm the icon against the real
release artifact.

- [ ] Confirm the release job selected **Xcode 26.6** and `actool` compiled the
      icon with no crash/warning.
- [ ] In the built `.app`: `Contents/Resources/Assets.car` contains the `AppIcon`
      renditions (`assetutil --info … | grep -i AppIcon`), a fallback `*.icns` is
      present, and `CFBundleIconName` is set.
- [ ] **macOS < 26 light fallback**: on a real macOS 15 machine the app shows the
      light icon (Finder + Dock).
- [ ] **macOS 26**: light/dark render correctly per System Settings → Appearance →
      Icon & Widget Style (Default keeps light even in Dark mode; Dark/Auto shows
      the dark variant).

### Folder sizes & sync progress (PR #74)
Visually confirm in the release artifact, on a profile with nested-folder changes:

- [ ] Folder rows show an aggregate **size** (sum of the changed items beneath
      them); a pure-deletion / prop-only folder is blank.
- [ ] During a sync, **expanded** folders show an aggregate progress bar (not just
      collapsed ones), advancing alongside each child's own bar; no UI stall on a
      large reconciliation.
- [ ] A **hybrid directory** (a directory that is itself a reconcile item with
      changed descendants) appears as an **expandable** folder — its disclosure
      triangle reveals its children, and its own row remains selectable.

> If any validation item fails, open a tracking issue and fix before release.
> (This section supersedes the standalone icon issue #75.)
