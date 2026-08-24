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

### Key rotation (EdDSA) — NOT supported by the current one-key pipeline

**The current release pipeline cannot rotate the EdDSA key.** This is a real
limitation, documented here so no one attempts a rotation that would strand
clients. Treat the EdDSA private key as effectively un-rotatable and guard it
accordingly.

**Why.** A rotation would have to ship a *transition* release that (a) carries the
**new** `SUPublicEDKey` (to teach clients the new key) and (b) is still accepted by
**existing** clients. Existing clients run a **fail-closed** feed policy
(`SURequireSignedFeed: true` + `SUSignedFeedFailureExpirationInterval: 0`, see
`project.yml`), so they accept an appcast only if its **feed-level** signature is
made with the key they already trust — the **old** key — and there is no automatic
recovery if that fails. But the pinned Sparkle 2.9.6 tools and a single-feed design
make an in-band rotation impossible:

- `generate_appcast` emits an archive's `edSignature` **only when the archived
  app's `SUPublicEDKey` matches the private key it is signing with**; on a mismatch
  it prints `Warning: SUPublicEDKey in the app … does not match key EdDSA in the
  Keychain` and emits **no** signature
  ([Appcast.swift](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/generate_appcast/Appcast.swift#L178-L218)).
  Our structural gate (`scripts/verify-appcast-signatures.sh`) then rejects the
  feed. So a transition bundle carrying the **new** public key gets only a
  **new-key** archive signature — existing clients must accept its archive via the
  stable **Developer ID** path, not EdDSA.
- A single appcast feed carries only **one** feed-level signature. `sign_update`
  **can** re-sign a feed's XML directly with any key — it extracts the existing
  content and writes the replacement atomically
  ([sign_update main.swift](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/sign_update/main.swift#L235-L249))
  — so an old-key feed *or* a new-key feed is each producible. What is impossible is
  **one** feed that satisfies **both** client generations: existing clients require
  an old-key feed signature, while a client that has installed the transition app
  trusts the **new** key and rejects an old-key feed.
- `generate_keys` with the default account does not create a second key — it
  **reuses** the existing keychain key; a distinct key needs a separate `--account`
  (or explicit export/remove/import)
  ([main.swift](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/generate_keys/main.swift#L159-L187)).

**What a supported rotation would require (unimplemented).** Because the two client
generations need different feed signatures, a correct rotation needs **two feed
URLs**, not one: an **old-key-signed transition feed** kept at the current
`SUFeedURL` for existing and dormant clients (whose archives they accept via the
stable Developer ID path), and a **new-key-signed feed** at a NEW `SUFeedURL` baked
into the transition app. The transition app ships both the new `SUPublicEDKey` and
the new feed URL; once an existing client installs it, it follows the new feed
thereafter. This needs the new key generated under its own keychain `--account`,
each feed (re-)signed with `sign_update` under the appropriate key, the old feed
retained as long as any dormant client may still poll it, and a fixture using two
throwaway keys + the pinned Sparkle tools proving an **old-key** client validates
the transition feed and a **new-key** client validates the new feed. None of that
exists today. Until it does, do not rotate.

**If the key is ever compromised or lost.** Existing auto-update clients cannot be
migrated in-band. Recovery is out-of-band: publish a fresh signed + notarized build
to GitHub Releases and tell users (README + release notes) to **re-download and
replace the app manually**. A manual install carries the new `SUPublicEDKey` and
resumes normal auto-updates; clients that never re-download stay on the old key.

**Do not casually touch the release secret.** Replacing `SPARKLE_ED_PRIVATE_KEY`
*is* an EdDSA key change and — given the above — would break auto-updates for every
existing client with no in-band recovery. It already lives only in the maintainer's
login keychain and the reviewer-gated CI secret; keep it that way. (Separately, and
for the same fail-closed reason, never change the EdDSA key and the Developer ID
certificate together — but note that EdDSA rotation is not currently supported at
all.)

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
`SUFeedURL`. On a pushed `v*` tag, the `release` job in
`.github/workflows/release.yml` produces and publishes it automatically. The
appcast is generated, signed, and **cryptographically verified before the
GitHub Release is created and the archive uploaded** (deliberately: the signed
feed is proven over local bytes first). The Release is then created/uploaded,
the verified appcast is published to GitHub Pages, and finally the served feed
is re-verified byte-for-byte:

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
   which GitHub Pages serves at `SUFeedURL`. Archives live on GitHub Releases.
6. **Verify publication:** poll `SUFeedURL` until it serves the new version, then
   `sign_update --verify` the served bytes — a green `git push` is not proof the
   asynchronous Pages deploy succeeded.

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
