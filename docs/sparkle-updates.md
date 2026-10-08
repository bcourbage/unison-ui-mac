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

What that OR means in practice, now that the Release build is Developer
ID-signed and notarized:

- The code-signing branch is live: a Developer-ID-matched update (same team)
  could install even if its EdDSA signature were missing or wrong. Keep
  EdDSA-signing every update anyway and treat the EdDSA private key as
  security-critical.
- EdDSA is enforced on the publish path by two gates in the release pipeline:
  `scripts/verify-appcast-signatures.sh` (**structural** — every parsed enclosure
  carries a well-formed, correctly located, 64-byte Sparkle edSignature) and
  `scripts/verify-appcast.py` (**cryptographic**). The crypto gate does not
  reimplement any signature parsing: it delegates to the pinned **`sign_update
  --verify`** (Sparkle's own verifier), confirming the feed-level signature and
  the new archive's signature over its bytes, matched by the **exact** expected
  release URL. The feed-level signature is what authenticates every enclosure
  URL and edSignature carried forward in the feed; the crypto gate does not
  independently constrain every enclosure URL to a Releases prefix (that
  enclosure-set shape is the structural gate's job).

**Feed-level signature (`SURequireSignedFeed`).** On top of the per-archive
signature, Sparkle 2.9.6 signs the whole appcast: `generate_appcast` appends a
trailing `<!-- sparkle-signatures: ... -->` block carrying an Ed25519 signature
over the feed body, using the same maintainer key. With `SURequireSignedFeed =
true` in the app (it requires `SUVerifyUpdateBeforeExtraction = true`, which is
set, or the updater refuses to start), the client rejects any appcast whose
feed-level signature is missing or invalid. `generate_appcast` emits it
automatically because the archived app's Info.plist carries the key. We also set
**`SUSignedFeedFailureExpirationInterval: 0`**: Sparkle otherwise recovers into
unsigned-feed handling after ~20 days of continuous feed-signature failures (a
key-rotation escape hatch), and `0` disables that recovery so enforcement stays
permanently fail-closed. Because the whole feed body is signed, carrying old
items forward is only safe if the seed feed is authenticated first — so the
release job runs `sign_update --verify` on the downloaded feed **before** reusing
it, and fails closed on any tamper (a fetch error other than 404 also fails,
rather than silently starting a fresh feed).

Separately, **Apple notarization** (a stapled ticket) is what lets Gatekeeper
accept the *first* download from GitHub Releases without a quarantine prompt; a
Sparkle-delivered update installs without setting the quarantine attribute
regardless. Notarization is wired in the signing phase (`install.sh`,
`.github/workflows/release.yml`).

## The EdDSA key (one-time, maintainer-owned)

The private key is the single most sensitive secret in the release process:
anyone holding it can sign an update the app will accept. It is created once and
its canonical copy lives in the **login keychain**. It is **never committed to
the repo**. A copy is stored as the **gated GitHub Actions secret**
`SPARKLE_ED_PRIVATE_KEY` (encrypted at rest by GitHub, injected as an env var
only in the reviewer-gated `release` environment, and read on stdin by the
signing tools — never on argv or disk in the runner). Setting that secret is a
one-time manual step in the repo settings; treat it with the same care as the
keychain copy.

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

### Key rotation and recovery

The feed policy is **fail-closed** (`SURequireSignedFeed: true` with
`SUSignedFeedFailureExpirationInterval: 0`, see `project.yml`): a client accepts
an appcast only when its feed-level signature verifies with the public key the
client carries, and there is no fallback to unsigned-feed handling. That is
deliberate and it stays. Everything below follows from it.

Sparkle provides a supported rotation path for Developer ID-signed apps
([Rotating signing keys](https://sparkle-project.org/documentation/#rotating-signing-keys)):
an update may change **either** the EdDSA key **or** the Developer ID
certificate, never both at once, and with `SUVerifyUpdateBeforeExtraction` an
EdDSA change requires the update archive to be a **Developer ID-signed disk image
(DMG)**. The project relies on that mechanism; it does not maintain a second
feed.

**Rotate only when necessary**: a compromised key, a Developer ID certificate
change (the current certificate expires 2031-08-22), or a Sparkle-mandated
algorithm change. Never rotate routinely.

#### The cases

| Situation | Outcome |
| --- | --- |
| Key A valid, normal update | Automatic. |
| Key A **compromised but still available** | Automatic A → B rotation: one transition release whose bundle carries public key B, delivered as a Developer ID-signed DMG, listed in a feed signed with **A**. Clients install it through the Developer ID path and are anchored to B; the next release is signed with B. |
| Client installed the transition, next release signed with B | Automatic. |
| Key A **lost** | Automatic recovery is **impossible** by design (the client cannot validate any feed, and the expiration fallback is off). Recovery is a one-time manual reinstall from GitHub Releases; the fresh install carries the current key and updates resume. |
| Dormant key-A client after the feed moves to B | It rejects the B-signed feed and never recovers on its own; a one-time manual reinstall is required. Accepted trade-off unless real-world usage shows a need for a legacy feed. |
| Developer ID certificate change | Automatic through the same mechanism, with the EdDSA key **unchanged** in that release. No DMG requirement applies to this direction. |

How the pinned 2.9.6 tools fit: `generate_appcast` signs an archive only when the
archived app's `SUPublicEDKey` matches the signing key, so the transition archive
(carrying B) can only be B-signed; existing clients accept it via Developer ID,
which is why it must be a Developer ID-signed DMG. `sign_update` can re-sign a
feed with either key. A second key needs its own keychain `--account`.

#### Rotation procedure (compromise, key still available)

Not yet rehearsed end to end; the fixture that proves each row above on a single
feed is the post-1.0 half of #108 and is tracked in TODO.md. Until it exists,
treat this as the plan, and expect to validate each step on a throwaway feed first.

1. Generate key B under a new account: `generate_keys --account unison-ui-mac-b`.
2. Build the transition release with `SUPublicEDKey` = B's public key and package
   it as a **Developer ID-signed DMG** (the pipeline ships a ZIP today; this step
   needs adding).
3. Sign the transition archive with B; publish a feed listing it, with the feed
   signed with **A** (`sign_update` under A's account).
4. Leave that feed in place for a chosen migration period, publishing nothing
   else. Clients that update during it move to B.
5. Switch the feed to B-signed releases. Record in the release notes that an
   install dormant across the period needs a one-time reinstall.
6. Replace the `SPARKLE_ED_PRIVATE_KEY` secret with B only after step 5.

Never change the EdDSA key and the Developer ID certificate in the same release.

#### Key custody (the part that matters before 1.0)

The lost-key row is survivable but costly, so prevent it operationally. Sparkle's
own guidance is to keep the private key secure and away from the update host,
and `generate_keys` exports and imports it for exactly this purpose.

**Export into an encrypted image, never onto the plain disk.** The export file is
the key in plaintext, so create an encrypted disk image first and export straight
into it:

```bash
hdiutil create -size 5m -fs HFS+J -encryption AES-256 -volname SparkleKeyBackup SparkleKeyBackup.dmg
hdiutil attach SparkleKeyBackup.dmg -nobrowse -mountpoint /Volumes/SparkleKeyBackup
./bin/generate_keys -x /Volumes/SparkleKeyBackup/sparkle-private-key.txt
hdiutil detach /Volumes/SparkleKeyBackup
```

- The image's passphrase is the only protection once copies are online, so make it
  long and random, and keep it **somewhere that does not depend on the same account
  as a copy of the image** (an image in iCloud Drive and a passphrase in the same
  Apple account fall together) and that is recoverable without your memory alone.
- Keep **at least two copies** of the image in separate places, apart from the Mac
  holding the keychain and from the update host. A copy on a medium that depends on
  no online account is the most robust; cloud copies and a second machine are
  acceptable. Record that each copy's SHA-256 matches the original.
- The export file is as sensitive as the keychain entry: it must never land in the
  repo, a shared drive, or a chat. Do not keep a plaintext copy on any disk.

**Prove a copy restores.** Mount it only **read-only and at an explicit mount
point**, so the image file's bytes cannot change (a synced copy would otherwise
propagate the change) and a stale volume of the same name cannot be mistaken for
it. Check first that nothing named `SparkleKeyBackup` is already mounted:

```bash
hdiutil attach SparkleKeyBackup.dmg -readonly -nobrowse -mountpoint /Volumes/custody-restore
```

Import the key under a separate Sparkle keychain account so the production item is
never touched (`generate_keys` only adds items, and keys them by service and
account), or on a throwaway macOS user or VM for the stricter test:

```bash
./bin/generate_keys --account custody-test -f /Volumes/custody-restore/sparkle-private-key.txt
./bin/generate_keys --account custody-test -p
```

The second command must print the production public key, byte for byte equal to
`SUPublicEDKey` in `project.yml`. Then sign a scratch file with the restored key and
verify the signature. `sign_update --verify --ed-key-file` does not accept a bare
32-byte public key; it reads the key from the last 32 bytes of a 96-byte blob, which
`scripts/make-verifier-key.py` builds from `SUPublicEDKey` with no private material
(the same construction `pages.yml` and `scripts/verify-appcast.py` use):

```bash
pub="$(sed -n 's/^ *SUPublicEDKey: //p' project.yml)"
sig="$(./bin/sign_update --account custody-test -p scratch.txt)"   # signature only
python3 scripts/make-verifier-key.py "$pub" \
  | ./bin/sign_update --verify --ed-key-file - scratch.txt "$sig" && echo verified
```

Tamper with `scratch.txt` and run the verify command again: it must now fail
(`Error: failed to pass signing verification.`), otherwise the check proves nothing.
Then clean up, removing only the test item, and confirm the production key is
intact:

```bash
security delete-generic-password -s "https://sparkle-project.org" -a custody-test
./bin/generate_keys -p
hdiutil detach /Volumes/custody-restore
```

This custody check is a 1.0 release gate in `docs/release-checklist.md`.

**Do not casually touch the release secret.** Replacing `SPARKLE_ED_PRIVATE_KEY`
*is* an EdDSA key change: do it only as step 6 of a rotation that has shipped its
transition release, never on its own.

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
`SUFeedURL`. **Two endpoints, distinct roles:** GitHub Pages
(`https://bcourbage.github.io/unison-ui-mac/appcast.xml`) is the **signed origin**
that the release job publishes to; `SUFeedURL`
(`https://updates.courbage.net/unison-ui-mac/appcast.xml`) is the **client-facing**
URL baked into the app, a Cloudflare Worker that fetches the origin and returns it
BYTE-FOR-BYTE (feed signature intact) while logging the anonymous update-check
profile (its source is the separate private repo
[`bcourbage/unison-updates-worker`](https://github.com/bcourbage/unison-updates-worker),
not part of this repository). Builds released before that switch
poll GitHub Pages directly.

On a pushed `v*` tag, the `release` job in `.github/workflows/release.yml` produces
and publishes it automatically. The appcast is generated, signed, and
**cryptographically verified before the GitHub Release is created and the archive
uploaded** (deliberately: the signed feed is proven over local bytes first). The
Release is then created/uploaded, the verified appcast is published to the GitHub
Pages origin, and finally BOTH endpoints (origin, then the client `SUFeedURL`) are
re-verified byte-for-byte:

1. **Fetch the Sparkle tools** from the pinned, checksum-verified tarball (same
   SHA-256 as "Getting the tools" above) — provides both `generate_appcast` and
   `sign_update`.
2. **Authenticate the seed feed + check build monotonicity.** Download the
   currently-published `appcast.xml` (so older versions survive —
   `generate_appcast` copies forward items whose archive is not present locally).
   Before reusing it, run `verify-appcast.py --feed-only` (= `sign_update
   --verify`) on it so a tampered feed cannot smuggle forged carried-forward
   metadata into a freshly-signed release. A 404 is accepted as "start a fresh
   feed" **only for the seed tag `v0.5.0`** (`FIRST_SPARKLE_TAG` in
   `release.yml`); for every later tag a 404 (or any other fetch error) **fails
   the job closed**, so a Pages deletion, routing mistake, or transient 404
   cannot silently truncate the feed and bypass seed authentication and
   monotonicity. The new `CURRENT_PROJECT_VERSION` must be a positive integer
   greater than every `sparkle:version` already in the authenticated feed.
3. **Generate + sign:** `generate_appcast --ed-key-file -` (private key on stdin,
   from the `SPARKLE_ED_PRIVATE_KEY` secret) with `--download-url-prefix` pointing
   at the GitHub Releases asset URL for the tag, plus the new `.app.zip` and the
   release notes as an embedded HTML fragment (`scripts/release-notes-to-html.py`
   turns `notes.md` into `unison-ui-mac-<version>.app.html`). Because the archived
   app's Info.plist has `SURequireSignedFeed`, this emits both the per-enclosure
   signatures and the feed-level signature.
4. **Two verification gates (fail closed):** `verify-appcast-signatures.sh`
   (structural — enclosure shape/location/qualified-name via `xmllint name()`)
   then `verify-appcast.py --archive <zip> --expected-url <exact Releases URL>`
   (cryptographic, via `sign_update --verify`: the feed-level signature
   authenticates the whole feed body, and the new archive's signature verifies
   over its bytes, matched by its EXACT expected URL so a foreign/duplicate
   enclosure or a dot-segment URL cannot stand in for it).
5. **Publish** `appcast.xml` to the `gh-pages` branch (which must already exist),
   the signed **origin** GitHub Pages serves. Archives live on GitHub Releases.
   `SUFeedURL` (the Worker) fetches this origin; it is not itself published to.
6. **Verify publication at both endpoints:** poll the GitHub Pages **origin** until
   it serves the new version and `sign_update --verify` the served bytes (a green
   `git push` is not proof the asynchronous Pages deploy succeeded); then poll the
   client-facing `SUFeedURL` (the Worker, which may lag the origin by up to its
   short cache TTL) until byte-identical and verify those bytes too, proving clients
   can actually see the release. Rollback must likewise restore the origin AND wait
   out / purge the Worker cache before deleting an asset (see the release
   checklist).

For **local testing** (not a real release), the manual wrapper still works:
`SPARKLE_BIN="$tools/bin" ./scripts/sparkle-appcast.sh path/to/updates/` runs
`generate_appcast` plus the structural gate against a folder of archives.

### The CI signing key (`SPARKLE_ED_PRIVATE_KEY` secret)

CI runners have no login keychain, so the EdDSA private key is provided to the
`release` environment as the `SPARKLE_ED_PRIVATE_KEY` secret and passed to
`generate_appcast` on **stdin** (never argv). Its value is the base64 private key
exported from the maintainer keychain:

```bash
./bin/generate_keys -x sparkle-private-key.txt   # writes the base64 private key
# paste the FILE CONTENTS as the SPARKLE_ED_PRIVATE_KEY secret, then:
rm -P sparkle-private-key.txt                     # do not keep the plaintext around
```

Set it only in the gated `release` environment (not repo-wide), like the
notarization secrets. It is the same key whose public half is `SUPublicEDKey`;
treat it as security-critical.

### GitHub Pages (one-time setup)

Pages must be configured to **Deploy from a branch → `gh-pages` → `/ (root)`**
(repo Settings → Pages). The `gh-pages` branch must already exist — the release
job requires it and commits `appcast.xml` to it, but does not create it (a
botched auto-create once published the whole repo tree). Nothing else is hosted
there (release notes are embedded in the feed, archives live on Releases).

## Testing the update cycle locally (without touching the production feed)

The production feed is live (first published with v0.5.0). To exercise the full
cycle safely, point a local build at a local appcast instead of the production
`SUFeedURL`, so nothing you test touches the published feed:

1. Build and archive the current version, and a build with a higher
   `MARKETING_VERSION` **and** a higher `CURRENT_PROJECT_VERSION` (Sparkle
   compares the build number), into an `updates/` folder.
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
