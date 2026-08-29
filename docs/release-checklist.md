# Release checklist

Validation steps for a release, grouped by **when** they can actually run under
the current `release.yml`. That workflow is split into three jobs: **build**
(unsigned Release + tests, uploads the app artifact), **smoke-macos15** (launches
that exact artifact on a macOS 15 runner and *gates* the release), and
**release** (signs the **same** artifact with Developer ID, notarizes, staples,
then creates the public Release and publishes the live feed). So the bytes the
smoke job validated are the bytes that get signed, and the macOS-15 launch is a
real pre-publication gate — but there is still no pause for *manual* testing
before publication:

- **Pre-tag checks** (repo state, before you tag): `main` is green; the vendored
  blob checksum matches `vendor/README.md`; the product-site pages are current for
  the release.
- **Pre-publication gates** (automated, *inside* the release run — a failure
  fails the run, so nothing is published): the app and its embedded OCaml runtime
  are built for the macOS 15 minimum (`verify-runtime-minos`, zero
  deployment-version linker warnings) and the built bundle's Mach-O floors are
  verified (`verify-bundle-minos`); the **exact** unsigned Release artifact
  launches cleanly on a macOS 15 runner (`smoke-macos15`); then Developer ID
  signing, notarization + stapling, appcast **seed-authentication**,
  **build-monotonicity**, and the in-job `verify-appcast.py`.
- **Post-publication canaries** (require the built, signed, notarized artifact,
  which exists only as the job's **output** — by the time you can inspect it, the
  Release and live feed are already public): every manual check against the
  artifact — version/signature/notarization inspection, the symbol/string
  assertions, the TC9b/TC11/TC13 lifecycle runs, and the installed previous-
  version update test. A failure here is an **incident handled by rollback**, not a blocked
  publication. Making any of these a true gate would require splitting the
  workflow with a protected manual-promotion stage.

The mechanical cut (version bump, CHANGELOG, `release-notes/<version>.md`, tag →
workflow → Homebrew cask bump) is in the release runbook.

## Every release

- [ ] **(pre-tag)** `main` is green.
- [ ] **(pre-tag)** Vendored blob checksum matches `vendor/README.md`.
- [ ] **(pre-tag)** The product-site pages are accurate for this release. Review the
      landing page, Install, FAQ, and Credits (under `site/`) and update screenshots,
      feature/FAQ copy, and install steps as needed. `/manual/` and version fields
      regenerate from `MANUAL.md` and `project.yml` / `Makefile` on deploy; the rest
      is manual. The site deploys from `main` via `pages.yml`, which preserves
      `appcast.xml` byte-for-byte, so this is independent of the feed publish.
- [ ] **(pre-publication gate — in-job)** The release build (`release.yml`,
      Release configuration) is built from the exact tagged commit. (Cannot be
      confirmed before the tag exists; it is the job's checkout/build guarantee.)
- [ ] **(post-publication canary)** The built artifact reports the right
      `MARKETING_VERSION (CURRENT_PROJECT_VERSION)`, minimum macOS, a Developer ID
      signature with a hardened runtime, a stapled notarization ticket, and no
      Debug/autotest symbols. (The signing/notarization steps that PRODUCE this
      are pre-publication gates in the job; inspecting the finished artifact
      happens after it is published.)

## 0.6.0

Build **21** (v0.6.0), on top of 0.5.1 (build 20). No profile/settings migration.

### macOS 15 deployment baseline — PRE-PUBLICATION GATES (new in 0.6.0)
0.6.0 makes the macOS 15 minimum genuine (the OCaml runtime is built *for* 15, not
relabelled) and wires it into `release.yml` as real gates that block publication.
Confirm from the release run's logs (these fail the run if they regress, so a
green run is the confirmation; the manual bullet is a belt-and-suspenders check):

- [ ] **(pre-publication gate — in-job)** `verify-runtime-minos` passed (every
      linked OCaml runtime archive is `minos 15.0`) and the Release build emitted
      **zero** "was built for newer macOS version" linker warnings.
- [ ] **(pre-publication gate — in-job)** `smoke-macos15` launched the **exact**
      unsigned Release artifact on a macOS 15 runner and it exited cleanly, before
      the `release` job signed that same artifact.
- [ ] **(post-publication canary)** On the finished signed `.app`, every Mach-O in
      the bundle is `minos <= 15.0` and the main binary is exactly `15.0`
      (`scripts/verify-bundle-minos.sh <app>` — the in-job step, re-runnable on the
      artifact).

### First 0.5.1 → 0.6.0 Sparkle auto-update — POST-PUBLICATION CANARY
Second end-to-end exercise of the update + appcast **seed-authentication /
build-monotonicity** paths against the published feed (0.5.1 was the first).

- [ ] **(pre-publication gate — in-job)** The release job authenticated the
      published `appcast.xml` and passed build-monotonicity (build **21** > 20),
      rather than any first-release/404 path. (Failure fails the run; nothing is
      published.)
- [ ] **(post-publication canary)** On a machine running an **installed 0.5.1**:
      App menu ▸ Check for Updates finds 0.6.0, downloads it, verifies the EdDSA
      signature, and installs it through the app (no Gatekeeper prompt on the
      Sparkle-delivered update).
- [ ] **(post-publication canary)** After the update, the About panel shows
      **0.6.0 (build 21)**.

#### If the 0.6.0 canary fails (installer / Gatekeeper / update problem)
`release.yml` creates the public Release and publishes the live appcast **before**
the installed-0.5.1 manual test can run, so by the time this fails, 0.6.0 is
already being offered to users. Treat a failure as an incident and withdraw it in
this exact order (restore the served feed **before** removing the asset, or
clients are left a signed 0.6.0 enclosure pointing at a deleted archive):

1. **Restore the exact last-good v0.5.1 signed feed.** Put the last-good (v0.5.1)
   signed `appcast.xml` back on the `gh-pages` branch verbatim — its trailing
   `<!-- sparkle-signatures -->` block must be intact — and push. The *served*
   feed is what clients poll.
2. **Verify propagation before touching the asset.** Pages deploys
   asynchronously, so poll the live feed until it is byte-identical to the
   restored file, then cryptographically verify the served bytes (`SPARKLE_BIN`
   is the checksum-pinned Sparkle tools dir; `sign_update --verify` reads the
   maintainer key from the login Keychain):
   ```sh
   feed=https://bcourbage.github.io/unison-ui-mac/appcast.xml
   good=/path/to/last-good/appcast.xml        # the exact v0.5.1 bytes pushed in step 1
   until curl -fsS "$feed" -o served.xml && cmp -s served.xml "$good"; do sleep 5; done
   "$SPARKLE_BIN/sign_update" --verify served.xml   # must report a valid feed signature
   ```
   Restoring the origin is necessary but NOT sufficient: current builds poll the
   Worker, not GitHub Pages directly.
3. **Verify the client-facing proxy before touching the asset.** Builds released
   with the new `SUFeedURL` poll
   `https://updates.courbage.net/unison-ui-mac/appcast.xml`, a Cloudflare Worker
   that caches the origin for 60s and sends `Cache-Control: max-age=60`. After the
   origin is restored, purge the Cloudflare cache (or wait past the full TTL), then
   poll the proxy until it is byte-identical to the restored feed and
   cryptographically verify those exact proxy-served bytes:
   ```sh
   proxy=https://updates.courbage.net/unison-ui-mac/appcast.xml
   sleep 90   # > the 60s Worker cache TTL + margin; or purge the CF cache instead
   until curl -fsS "$proxy" -o proxy.xml && cmp -s proxy.xml "$good"; do sleep 5; done
   "$SPARKLE_BIN/sign_update" --verify proxy.xml   # valid signature over the PROXY bytes
   ```
   Only once the proxy serves the restored feed do new clients stop being offered
   0.6.0. A single check right after restore is not enough if other edge locations
   may still hold the old response; prefer an explicit purge or a full-TTL wait.
4. **Then remove the 0.6.0 download.** `gh release delete-asset` the 0.6.0 archive
   (or `gh release delete` the whole release). **Marking it a prerelease is NOT
   sufficient** — prerelease assets stay downloadable.
5. **Do not merge the Homebrew cask bump** for 0.6.0; if it was already merged,
   **revert it** so `brew install --cask` stops offering 0.6.0.
6. **Fix forward as v0.6.1 (build 22).** Never delete or reuse the `v0.6.0` tag.

### Manual installer hardening (optional spot-check)
0.6.0 hardened `install.sh` (Release-only, atomic stage-then-swap, verified
quarantine strip). Homebrew-cask users are unaffected; if validating the manual
path:

- [ ] `./install.sh` with only a Debug build present fails with a clear "no
      Release build" message (no Debug fallback).
- [ ] A normal `make install` replaces an existing install atomically and the app
      launches without a Gatekeeper quarantine prompt.

### Carried-forward canaries (still apply)
The 0.5.1 scan-interruption artifact assertions and lifecycle re-runs (TC9b /
TC11 / TC13, and the symbol/string checks) are unchanged in 0.6.0 — re-run them
against the signed 0.6.0 RC as documented under **0.5.1** below.

## 0.5.1

### First real 0.5.0 → 0.5.1 Sparkle auto-update (TODO #1) — POST-PUBLICATION CANARY
0.5.0 was the first Sparkle build, so there was no prior client to update *from*;
0.5.1 is the first end-to-end exercise of the update path AND the first time
`release.yml` runs the appcast **seed-authentication + build-monotonicity** paths
against a **published** feed (0.5.0 took the first-release 404 path).

**This is a canary, not a pre-publication gate.** The workflow creates the public
GitHub Release, publishes the live appcast to Pages, and verifies the served feed
*before* the installed-0.5.0 manual test can run — so by the time this test runs,
0.5.1 is already being offered to users. Treat a failure as an incident, not a
blocked merge.

**If the canary fails (installer/Gatekeeper/update problem):** withdraw the
release, in this exact order (the order matters — restoring the feed before
removing the asset avoids leaving clients a signed 0.5.1 enclosure that points at
a deleted archive):

1. **Restore the exact last-good signed feed.** Put the last-good (v0.5.0) signed
   `appcast.xml` back on the `gh-pages` branch verbatim (its trailing
   `<!-- sparkle-signatures -->` block must be intact) and push. The *served*
   feed is what clients poll.
2. **Verify propagation before touching the asset.** Pages deploys
   asynchronously, so poll the live feed until it is byte-identical to the
   restored file, then cryptographically verify the served bytes. `SPARKLE_BIN`
   is the checksum-pinned Sparkle tools dir (see `docs/sparkle-updates.md`);
   `sign_update --verify` reads the maintainer key from the login Keychain, so no
   key needs to be piped in:
   ```sh
   feed=https://bcourbage.github.io/unison-ui-mac/appcast.xml
   good=/path/to/last-good/appcast.xml        # the exact bytes pushed in step 1
   until curl -fsS "$feed" -o served.xml && cmp -s served.xml "$good"; do sleep 5; done
   "$SPARKLE_BIN/sign_update" --verify served.xml   # must report a valid feed signature
   ```
   Restoring the origin is necessary but NOT sufficient once `SUFeedURL` points at
   the Worker: current builds poll the proxy, not GitHub Pages directly.
3. **Verify the client-facing proxy before touching the asset.** Builds released
   with the Worker `SUFeedURL` poll
   `https://updates.courbage.net/unison-ui-mac/appcast.xml` (Cloudflare Worker, 60s
   cache). After the origin is restored, purge the Cloudflare cache (or wait past
   the full TTL), then poll the proxy until byte-identical to the restored feed and
   cryptographically verify those exact proxy-served bytes:
   ```sh
   proxy=https://updates.courbage.net/unison-ui-mac/appcast.xml
   sleep 90   # > the 60s Worker cache TTL + margin; or purge the CF cache instead
   until curl -fsS "$proxy" -o proxy.xml && cmp -s proxy.xml "$good"; do sleep 5; done
   "$SPARKLE_BIN/sign_update" --verify proxy.xml
   ```
4. **Then remove the 0.5.1 download.** `gh release delete-asset` the 0.5.1
   archive (or `gh release delete` the whole release). **Marking it a prerelease
   is NOT sufficient** — prerelease assets stay downloadable.
5. **Fix forward as v0.5.2** (build 21). Never delete or reuse the `v0.5.1` tag.

If a true pre-publication gate is ever required, add a staged-feed / manual-
promotion step to `release.yml` (publish to a staging feed, verify, then promote
to the production feed).

- [ ] **(pre-publication gate — in-job)** The `v0.5.1` release job authenticated
      the published `appcast.xml` (feed signature) and passed the
      build-monotonicity check (build **20** > 19), rather than taking any
      first-release/404 path. (If this fails, the job fails and nothing is
      published.)
- [ ] **(pre-publication gate — in-job)** The appcast validates locally in the
      job, before publication: `scripts/verify-appcast.py` (feed signature + the
      new archive by exact URL) is green.
- [ ] **(automated post-publication canary)** The served feed is byte-identical
      to the signed one. The job's post-publish re-verification (release.yml
      "Verify the published appcast") runs **after** the Release and appcast are
      already public, so a failure there is a published-state incident (apply the
      rollback), not a pre-publication block.
- [ ] **(post-publication canary)** On a machine running an **installed 0.5.0**:
      App menu ▸ Check for Updates finds 0.5.1, downloads it, verifies the EdDSA
      signature, and installs it through the app (no Gatekeeper prompt on the
      Sparkle-delivered update).
- [ ] **(post-publication canary)** After the update, the About panel shows
      **0.5.1 (build 20)**.

### Scan-interruption withdrawal — actual-artifact assertions (post-publication canaries; issues #53 / #94)
Run against the **final signed Release** `.app` binary
(`…/Release/unison-ui-mac.app/Contents/MacOS/unison-ui-mac`):

- [ ] **`signal_scan_transport` and `classify_reap` are ABSENT.**
      `nm <binary> | grep -E 'signal_scan_transport|classify_reap'` → no output.
- [ ] **"Stop Scan" and "Scan stopped" strings are ABSENT.**
      `strings <binary> | grep -E 'Stop Scan|Scan stopped'` → no output.
- [ ] **Shared transport-child registry/reaper symbols are PRESENT.**
      `nm <binary> | grep -E 'transport_child_terminated|reap_transport_children|track_child|retire_child'`
      → all four present (the connect-prompt classifier and shutdown reaping need them).
- [ ] **Scan-phase leave is Profiles; Stop is disabled (issue #117).** During a
      running scan the toolbar **Profiles** control leaves to the picker without
      cancelling the scan (it winds down in the background), and the **Stop**
      control is **disabled and neutral** (never "Return to Profiles", never
      "Stop Scan"). Stop's title stays "Stop" and its position does not move.
      Cross-check with TC11.
- [ ] **Sync-time Stop still operates normally.** During an actual sync, Stop is
      enabled and red and aborts the running transfer via `Abort.all` (unwinds at
      the next checkpoint), unchanged.

### Lifecycle re-runs on the signed Release candidate (post-publication canaries)
Behavior changed around scan-leave (#94) and TC11 was rewritten, so re-run these
against the **final signed RC** (not just a Debug build):

- [ ] **TC9b** (`docs/manual-test-step2b.md`) — pick a profile while a scan is
      running: the new open waits for the abandoned scan, then starts; the first
      profile's connection is closed, not leaked or clobbered.
- [ ] **TC11** (`docs/manual-test-step2b.md`) — post-auth transport wedge during
      a scan: reaches restart-required within the scan timeout; **Profiles** leaves
      to the picker (Stop is disabled, no "Stop Scan"); a waiting replacement
      profile is carried to restart-required; quit + reopen recovers cleanly.
- [ ] **TC13** (`docs/manual-test-step2b.md`) — auth prompt field style: the
      host-key yes/no question renders a **plain** field and every secret
      (password/passphrase/OTP) renders a **masked** secure field. (The combined
      host-key+password-chunk case stays unit-tested.)

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
