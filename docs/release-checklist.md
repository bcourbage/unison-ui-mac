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
