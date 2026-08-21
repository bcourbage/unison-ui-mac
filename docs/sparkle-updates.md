# Sparkle in-app updates — maintainer reference

unison-ui-mac ships in-app updates via [Sparkle 2](https://sparkle-project.org).
The framework is embedded from the SPM package in `project.yml`
(`packages.Sparkle`, pinned by git **revision** — see "Pinning and supply
chain"); Xcode links, embeds, and signs `Sparkle.framework` (with its
`Autoupdate`, `Updater.app`, and the `Downloader`/`Installer` XPC services) into
the app bundle.

## How an update is trusted

Sparkle authenticates an update two ways, and its validator accepts the update
when **either** passes — the check is an OR, not an AND (`SUUpdateValidator`:
"Either DSA must be valid, or Apple Code Signing must be valid"):

1. **EdDSA (ed25519) signature** — Sparkle's own integrity check, independent
   of Apple. Every update archive is signed with a private key held only by the
   maintainer; the matching **public** key ships in the app as `SUPublicEDKey`.
   `SUVerifyUpdateBeforeExtraction = true` forces this check to run *before* the
   archive is unpacked, so a tampered archive never reaches the unarchiver.
2. **Apple code signing** — if the new app's Developer ID signature matches the
   running app's (same team), Sparkle accepts it even without a valid EdDSA
   archive signature. This is the key-rotation path.

What that OR means in practice:

- **Today (ad-hoc Release, no Developer ID):** the running app's designated
  requirement is cdhash-specific, so a *different* app cannot satisfy the
  code-signing branch. EdDSA is therefore effectively required, and every update
  MUST be EdDSA-signed — `scripts/sparkle-appcast.sh` refuses to publish an
  appcast with an unsigned enclosure.
- **After Developer ID signing lands:** the OR is live. A Developer-ID-matched
  update could install even if its EdDSA signature were missing or wrong, so
  keep EdDSA-signing every update anyway and treat the EdDSA private key as
  security-critical.

Separately, **Apple notarization** (a stapled ticket) is what lets Gatekeeper
accept the *first* download from GitHub Releases without a quarantine prompt; a
Sparkle-delivered update installs without setting the quarantine attribute
regardless. Notarization is wired in the signing phase (`install.sh`,
`.github/workflows/release.yml`).

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

`SUPublicEDKey` in `project.yml`
(`targets.unison-ui-mac.info.properties`) already holds the real public key —
it is not a placeholder to regenerate per build. It changes only on a key
rotation; when it does, the value must equal `generate_keys -p` and match what
the built bundle ships (verify with
`/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' <app>/Contents/Info.plist`).

**Key rotation:** Sparkle allows changing *either* the EdDSA key *or* the Apple
code-signing certificate in a given update, never both at once — otherwise an
older client can't validate the transition. Plan rotations accordingly.

## Getting the tools

The signing CLI tools ship in the Sparkle release tarball, version-matched to
the embedded framework. Verify the tarball against the pinned SHA-256 **before**
extracting or running anything from it — these tools handle signing:

```bash
tools="$(mktemp -d)"
curl -fL -o "$tools/Sparkle-2.9.6.tar.xz" \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz
echo "52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192  $tools/Sparkle-2.9.6.tar.xz" \
  | shasum -a 256 -c - || { echo "checksum mismatch — do NOT use"; exit 1; }
tar -xf "$tools/Sparkle-2.9.6.tar.xz" -C "$tools"   # -> $tools/bin/{generate_keys,sign_update,generate_appcast}
```

Then point `scripts/sparkle-appcast.sh` at the tools via `SPARKLE_BIN="$tools/bin"`.
When bumping Sparkle, recompute this checksum from the new version's tarball and
update it here in the same commit as the `project.yml` revision bump.

## Pinning and supply chain

`packages.Sparkle` in `project.yml` is pinned by git **revision**
(`ac2def2…` = tag 2.9.6), not by tag/version. A revision pin is content-
addressed: even if the upstream `2.9.6` tag were moved after an account
compromise, SPM still resolves this exact commit, whose `Package.swift` declares
the binary xcframework's checksum (which SPM then verifies). `Package.resolved`
would normally lock this too, but it lives inside the gitignored `.xcodeproj`,
so the revision pin here is the tracked source of truth. Bump by editing the
revision (and the tools checksum above) deliberately.

## Producing an appcast for a release

The appcast is an RSS feed listing available versions; the app polls it at
`SUFeedURL`. `generate_appcast` scans a folder of update archives, signs each
with the keychain EdDSA key, generates binary deltas, and writes `appcast.xml`:

```bash
SPARKLE_BIN="$tools/bin" ./scripts/sparkle-appcast.sh path/to/updates/
```

The wrapper fails (non-zero) if `generate_appcast` produces any enclosure without
a `sparkle:edSignature` — e.g. when the keychain key is missing or does not match
the app. That mismatch is only a *warning* from `generate_appcast` itself, so
never publish an appcast that skipped the wrapper's check.

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
custom events.

**Consent model (stated precisely):** with `SUPromptUserOnFirstLaunch = true`
(and `SUEnableAutomaticChecks` left unset), Sparkle asks on first launch whether
to check for updates automatically. That prompt includes an **"Include anonymous
system profile" checkbox that is checked by default**, so profiling is opt-*out*
within the prompt, not opt-in — a user who accepts the defaults enables it.
Nothing is sent before the user answers the prompt (no pre-consent request). A
stricter default-off opt-in would require custom consent wiring through the
updater delegate rather than Sparkle's stock checkbox; it is deliberately not
done here.
