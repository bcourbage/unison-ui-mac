# Sparkle in-app updates — maintainer reference

unison-ui-mac ships in-app updates via [Sparkle 2](https://sparkle-project.org).
The framework is embedded from the pinned SPM package in `project.yml`
(`packages.Sparkle`, `exactVersion`); Xcode links, embeds, and signs
`Sparkle.framework` (with its `Autoupdate`, `Updater.app`, and the
`Downloader`/`Installer` XPC services) into the app bundle.

## How an update is trusted

Two independent mechanisms protect an update, and Sparkle checks both:

1. **EdDSA (ed25519) signature** — Sparkle's own integrity check, independent
   of Apple. Every update archive is signed with a private key held only by the
   maintainer; the matching **public** key ships in the app as `SUPublicEDKey`.
   An archive whose signature doesn't verify is refused.
2. **Apple code signing + notarization** — a Developer ID signature plus a
   stapled notarization ticket lets Gatekeeper accept the updated app on
   relaunch without a quarantine prompt. Wired in the signing/notarization
   phase; see `install.sh` and `.github/workflows/release.yml`.

EdDSA is mandatory. Apple notarization is what makes the *first* download from
GitHub Releases launch cleanly and removes the ad-hoc caveats; a Sparkle-
delivered update installs without setting the quarantine attribute regardless.

## The EdDSA key (one-time, maintainer-owned)

The private key is the single most sensitive secret in the release process:
anyone holding it can sign an update the app will accept. It is created once,
lives in the **login keychain**, and is **never** committed to the repo or
pasted into CI as plaintext.

Generate it with Sparkle's tool (from the version-matched release tarball —
see "Getting the tools"):

```bash
./bin/generate_keys
```

This stores the private key in the keychain and prints the public key. To
re-print only the public key later (safe to share):

```bash
./bin/generate_keys -p
```

Put that public key into `project.yml` under
`targets.unison-ui-mac.info.properties.SUPublicEDKey`, replacing the
`REPLACE_WITH_SUPUBLICEDKEY_FROM_generate_keys` placeholder, then rebuild.

**Key rotation:** Sparkle allows changing *either* the EdDSA key *or* the Apple
code-signing certificate in a given update, never both at once — otherwise an
older client can't validate the transition. Plan rotations accordingly.

## Getting the tools

The signing CLI tools ship in the Sparkle release tarball, version-matched to
the embedded framework:

```bash
curl -fL -o /tmp/Sparkle-2.9.6.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz
tar -xf /tmp/Sparkle-2.9.6.tar.xz -C /tmp/sparkle-tools   # bin/generate_keys, bin/sign_update, bin/generate_appcast
```

Point `scripts/sparkle-appcast.sh` at that `bin/` via `SPARKLE_BIN`.

## Producing an appcast for a release

The appcast is an RSS feed listing available versions; the app polls it at
`SUFeedURL`. `generate_appcast` scans a folder of update archives, signs each
with the keychain EdDSA key, generates binary deltas, and writes `appcast.xml`:

```bash
SPARKLE_BIN=/tmp/sparkle-tools/bin ./scripts/sparkle-appcast.sh path/to/updates/
```

Host the resulting `appcast.xml` (and the archives it references) at the
`SUFeedURL` in `project.yml` — GitHub Pages on this repo is the intended home.

## Testing the update cycle locally (before the feed is live)

Until the production feed is published you can exercise the full cycle against a
local appcast:

1. Build and archive the current version, and a build with a higher
   `MARKETING_VERSION`, into an `updates/` folder.
2. Run `scripts/sparkle-appcast.sh updates/` to sign them and emit
   `updates/appcast.xml`.
3. Serve it locally (`python3 -m http.server` in `updates/`) and temporarily set
   `SUFeedURL` to `http://localhost:8000/appcast.xml`.
4. Launch the lower version and choose **Check for Updates…**; Sparkle should
   find, download, verify, and install the higher one.

Revert `SUFeedURL` to the production URL before committing.

## Metrics — system profiling only

`SUEnableSystemProfiling = true` sends an anonymous system/app profile (macOS
version, CPU type/cores, Mac model, RAM, CPU speed, app name/version, preferred
language) as query parameters on the update-check request, at most once per
week. It is not a usage-analytics platform — it cannot record feature usage or
custom events. Because `SUEnableAutomaticChecks` is left unset, the user is
prompted on first launch whether to check automatically, so both update checks
and the profiling that rides along with them are opt-in.
