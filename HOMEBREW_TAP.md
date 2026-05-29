# Homebrew tap setup + maintenance

Runbook for publishing `unison-ui-mac` via a personal Homebrew tap so end
users can install with:

```sh
brew tap bcourbage/tap
brew install --cask unison-ui-mac
```

This file covers two flows:

1. **One-time setup** — create the tap repo and the first cask formula.
   Done once, takes ~30 minutes.
2. **Version bump** — update the cask when a new release lands.
   Three-line edit, ~5 minutes per release.

Maintainer-facing doc; end users don't need to read this.

## Why a personal tap and not the upstream `homebrew-cask`

| Path                       | Setup effort | Review process | Discoverability |
|----------------------------|--------------|----------------|-----------------|
| Personal tap (this doc)    | One-time, low | None — your repo | One `brew tap` away |
| Upstream `homebrew-cask`   | PR + review  | Manual review, popularity bar | In default brew search |

Start with the personal tap. Upstream submission is a later move once
the project has demonstrated traction over a few releases. See
<https://docs.brew.sh/Acceptable-Casks> for the upstream criteria.

## Prerequisites

- A GitHub account that can create public repos (yours).
- Homebrew installed locally: <https://brew.sh>.
- A published GitHub Release with a `.app.zip` artifact and a known
  SHA-256. The current release at the time of writing:
  - Tag: `v0.1.1`
  - Asset: `unison-ui-mac-0.1.1.app.zip`
  - SHA-256: `d2b6e3b98e30bcd2b7159afe77aa927974d426e45cbd0714fea59c227c68c7ef`

Re-derive the SHA-256 yourself before publishing if you're skeptical of
the number in `CHANGELOG.md` (or before bumping the cask after a new
release):

```sh
curl -L -o /tmp/zip https://github.com/bcourbage/unison-ui-mac/releases/download/v0.1.1/unison-ui-mac-0.1.1.app.zip
shasum -a 256 /tmp/zip
```

## One-time setup

### 1. Create the tap repo (GitHub web UI)

1. Go to <https://github.com/new>.
2. Repository name: **`homebrew-tap`** (the `homebrew-` prefix is
   mandatory — Homebrew's CLI uses it to recognize a repo as a tap).
3. Description: `Homebrew tap for unison-ui-mac and any future macOS tools.`
4. Visibility: **Public** (`brew tap` clones anonymously).
5. Initialize with a README — you'll replace it in step 6.
6. Create.

### 2. Clone the tap locally

```sh
cd ~/Documents/Sources
git clone git@github.com:bcourbage/homebrew-tap.git
cd homebrew-tap
mkdir Casks
```

Homebrew looks for casks under `Casks/` at the tap root. (Formulae would
go under `Formula/`; we don't need any.)

### 3. Write the cask file

Create `Casks/unison-ui-mac.rb`. Replace `version` and `sha256` with
current values:

```ruby
cask "unison-ui-mac" do
  version "0.1.1"
  sha256 "d2b6e3b98e30bcd2b7159afe77aa927974d426e45cbd0714fea59c227c68c7ef"

  url "https://github.com/bcourbage/unison-ui-mac/releases/download/v#{version}/unison-ui-mac-#{version}.app.zip"
  name "Unison-UI-Mac"
  desc "Native macOS GUI for the Unison File Synchronizer"
  homepage "https://github.com/bcourbage/unison-ui-mac"

  # Mirror the .app's hard requirements so brew refuses to install on
  # incompatible hosts rather than letting the bundle quarantine into
  # an unusable state.
  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  # The .app inside the zip — brew symlinks it into /Applications.
  app "unison-ui-mac.app"

  # `brew uninstall --zap` removes user defaults too. Logs go to the
  # unified log (Console.app), not disk, so nothing else to clean.
  zap trash: [
    "~/Library/Preferences/net.courbage.unison-ui-mac.plist",
  ]
end
```

Key syntax notes:

- `version "X.Y.Z"` interpolates into the URL via `#{version}`. On
  version bump, change `version` and `sha256` — the URL updates
  automatically.
- `sha256` is mandatory. Homebrew verifies on download; protects users
  against tampering even though the artifact isn't notarized.
- `depends_on macos: ">= :sequoia"` is brew's symbolic name for macOS 15.
  (`:tahoe` would be macOS 26.)
- `depends_on arch: :arm64` blocks installation on Intel — the
  vendored OCaml blob is arm64-only.
- `app "unison-ui-mac.app"` is the lowercased on-disk bundle name (the
  PRODUCT_NAME we ship). Brew creates the `/Applications` symlink.
- `zap` runs on `brew uninstall --zap unison-ui-mac` only. List anything
  the app creates outside its bundle.

Things you do **not** need:

- No `livecheck` block. Brew detects new releases via the tag pattern.
- No `installer manual:` / `postflight`. Cask installer auto-strips
  quarantine via `xattr` and registers with LaunchServices.
- No signing affidavit. Casks accept ad-hoc-signed apps by default.

### 4. Test the cask locally

From the `homebrew-tap` working directory, install from the local file
(skipping the tap-fetch step):

```sh
brew install --cask --debug --verbose ./Casks/unison-ui-mac.rb
```

Expect to see:

- `==> Downloading https://github.com/.../unison-ui-mac-X.Y.Z.app.zip`
- `==> Verifying checksum for cask unison-ui-mac`
- `==> Installing Cask unison-ui-mac`
- `==> Moving App 'unison-ui-mac.app' to '/Applications/...'`

Verify the install worked:

```sh
ls -la /Applications/unison-ui-mac.app    # should be a symlink → /opt/homebrew/Caskroom/...
open /Applications/unison-ui-mac.app      # should launch clean — no Gatekeeper prompt
brew list --cask unison-ui-mac
brew info --cask unison-ui-mac
```

If the app launches cleanly and `brew info` shows correct metadata,
clean up before pushing the tap:

```sh
brew uninstall --cask unison-ui-mac
brew uninstall --cask --zap unison-ui-mac   # also removes the plist
```

### 5. Lint the formula

```sh
brew style ./Casks/unison-ui-mac.rb
brew audit --strict --online --cask ./Casks/unison-ui-mac.rb
```

`brew audit --strict` catches missing fields, URL/SHA mismatches,
malformed `depends_on`, version-extraction issues. Some warnings are
tap-irrelevant (e.g., "should be in homebrew-cask") and can be ignored
for a personal tap.

### 6. Update the tap's README

Replace the auto-generated README in the `homebrew-tap` repo with a
one-liner pointing at the upstream project + the install command:

```markdown
# bcourbage/homebrew-tap

Homebrew tap for [unison-ui-mac](https://github.com/bcourbage/unison-ui-mac).

## Install

\`\`\`sh
brew tap bcourbage/tap
brew install --cask unison-ui-mac
\`\`\`

See the [main repo](https://github.com/bcourbage/unison-ui-mac) for
documentation, manual, changelog, and bug reports.
```

(Replace the `\`\`\`` lines with real triple-backticks when you save it
— they're escaped here so this doc renders right.)

### 7. Push the tap

```sh
git add Casks/unison-ui-mac.rb README.md
git commit -m "Add unison-ui-mac 0.1.1 cask"
git push
```

### 8. Verify the end-to-end public install path

From a clean shell (not the tap's working directory), simulate what
real users will run:

```sh
# Uninstall the local-file install if it's still around
brew uninstall --cask unison-ui-mac 2>/dev/null || true

# What users will run
brew tap bcourbage/tap
brew install --cask unison-ui-mac
```

If this succeeds, the tap is live and discoverable.

### 9. Update the main repo's README

Add a "Quickest install" section near the top of `INSTALL.md` (or
`README.md`'s quick-install block), pointing at the brew command:

```markdown
### Quickest install (recommended for end users)

\`\`\`sh
brew tap bcourbage/tap
brew install --cask unison-ui-mac
\`\`\`

Homebrew handles the macOS quarantine strip automatically; first
launch is clean.
```

The Homebrew path becomes the primary recommended install method;
existing `make install` / manual `.app.zip` paths stay as alternatives
for developers and the brew-averse.

## Version bumps (recurring)

When a new release lands (`vX.Y.Z` tag pushed, `.app.zip` published
on GitHub Releases with a known SHA-256), the cask update is a
three-line edit:

```sh
cd ~/Documents/Sources/homebrew-tap

# Edit Casks/unison-ui-mac.rb:
#   - version "X.Y.Z"
#   - sha256 "<new-sha-256>"
# (URL updates automatically via the version interpolation.)

# Sanity check
brew audit --strict --online --cask ./Casks/unison-ui-mac.rb
brew install --cask ./Casks/unison-ui-mac.rb   # smoke test the new version

# Ship it
git add Casks/unison-ui-mac.rb
git commit -m "Bump unison-ui-mac to X.Y.Z"
git push
```

Users running `brew upgrade --cask unison-ui-mac` then pick up the new
version on their next upgrade.

## Gotchas

- **SHA mismatches on re-archiving.** `ditto` is deterministic on the
  same source tree, but small filesystem-metadata changes can shift
  the hash. Always compute SHA-256 from the artifact you actually
  uploaded to GitHub, not a local re-build.
- **Don't mirror `homebrew-cask`'s folder structure.** Personal taps
  are flat: `Casks/<name>.rb` at the tap root. Adding subdirectories
  breaks the cask resolution.
- **`brew audit --strict` will warn about upstream-tap concerns.** A
  few warnings ("Cask token has `-mac` suffix", "should be in
  homebrew-cask") are tap-irrelevant. Read them, dismiss them, move on.
- **The `version` string is parsed.** Stick to semver-shaped strings
  (`0.1.1`, `1.2.3`). Avoid `0.1.1-beta` unless you're prepared to
  also set `version :latest` or use `version "0.1.1,beta"` syntax.
- **Don't rename the cask token casually.** Once `unison-ui-mac` is
  the published name, changing it (e.g., to `unison-ui` or
  `unisonuimac`) breaks the install command for everyone who's
  bookmarked or shared the original.
- **Test SHA from the actual GitHub Release download URL, not a local
  file.** The artifact GitHub serves goes through their CDN; in rare
  cases small wrapping differences could matter. Always:
  ```sh
  curl -L -o /tmp/zip https://github.com/bcourbage/unison-ui-mac/releases/download/vX.Y.Z/unison-ui-mac-X.Y.Z.app.zip
  shasum -a 256 /tmp/zip
  ```

## When to submit to upstream `homebrew-cask`

Defer this until:

- The project has shipped 3+ releases on the personal tap without major
  hiccups.
- There's some signal of organic adoption (issues filed, mentions
  elsewhere, search-volume hints).
- You're prepared to maintain the cask under upstream's bump cadence
  (they have CI that updates SHAs automatically for many casks, but
  manual oversight is still needed).

Upstream submission process: open a PR to `Homebrew/homebrew-cask`
moving the formula in. Their review checks include SHA verification,
URL stability, naming conventions, and usefulness threshold. See
<https://docs.brew.sh/Adding-Software-to-Homebrew#cask> for the full
checklist.

## Future considerations

- **Auto-bumping on release.** Once the upstream-release artifact URL
  stabilizes, a small GitHub Action in `homebrew-tap` could open a PR
  against itself whenever a new `unison-ui-mac` Release is published.
  Pattern: `actions/checkout@v4` → `gh release view --json assets,sha`
  → `sed` the cask file → `gh pr create`. Worth doing once 3+ manual
  bumps confirm the pattern is stable.
- **Multi-version support.** Homebrew casks don't natively pin
  multiple versions side-by-side. If a user wants to install `0.1.x`
  but stay off `0.2.x`, they currently can't via brew. Document this
  as a "build from source" path if it ever becomes a concern.
- **Universal binary (arm64 + x86_64).** If/when an Intel build
  ships, drop the `depends_on arch: :arm64` line and rebuild the
  artifact as a universal binary. Single-architecture casks are
  fine until then.
