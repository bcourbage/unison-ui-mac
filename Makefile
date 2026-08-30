UNISON_SRC ?= $(HOME)/Documents/Sources/unison/src
OCAMLLIBDIR ?= $(shell ocamlc -where)
# Debug by default — matches Xcode's scheme default and the convention
# for dev-facing Makefiles. Debug builds carry `assert()` and Swift
# preconditions and compile faster on iteration. `make install`
# overrides this to Release internally (a user-facing install always
# wants the optimized binary). `make test` also hardcodes Debug.
# For an ad-hoc Release build pass `CONFIG=Release` to `make build`.
CONFIG ?= Debug

export UNISON_SRC
export OCAMLLIBDIR

# ----- OCaml blob: vendored by default, upstream-rebuild on demand -----
#
# `unison-blob.o` is the compiled OCaml core (Unison engine + the
# `uimacbridge.ml` callback surface) that the Swift app links against.
# Building it from upstream takes 5–10 min and requires a sibling
# checkout of `bcpierce00/unison`. To remove that friction from the
# everyday install path, a prebuilt blob is committed under
# `vendor/unison-blob-<version>-<arch>.o`; `make build` uses it
# automatically. The maintainer regenerates it via `make vendor-blob`
# whenever upstream Unison or our patches bump.
#
# See `vendor/README.md` for the provenance contract (which upstream
# commit + which patches were applied) and the rebuild recipe.
UNISON_VERSION ?= 2.54.0
# Exported so `xcodegen generate` can substitute ${UNISON_VERSION} into
# project.yml's bundled-manual resource path — keeping it in lockstep with
# VENDORED_MANUAL below instead of a hardcoded version that drifts on a bump.
export UNISON_VERSION
ARCH := $(shell uname -m)
VENDORED_BLOB := $(CURDIR)/vendor/unison-blob-$(UNISON_VERSION)-$(ARCH).o
UPSTREAM_BLOB := $(UNISON_SRC)/unison-blob.o

# ----- Pinned OCaml toolchain -----
#
# The vendored blob is compiled OCaml, and its runtime ABI is version-locked:
# the app must LINK it against the SAME OCaml major.minor runtime (libasmrun.a,
# libcamlstrnat.a from $(OCAMLLIBDIR) = $(shell ocamlc -where)). A silent
# Homebrew upgrade to a newer OCaml would break linking (undefined caml_*
# symbols) or, on a rebuild, produce a different blob. So the blob rebuild AND
# app linking pin this exact version; CI/release install it via opam (see the
# workflows) rather than following an unversioned `brew install ocaml`.
# `check-ocaml-version` fails loudly on a mismatch.
OCAML_PINNED_VERSION := 5.5.0

.PHONY: check-ocaml-version
check-ocaml-version:
	@have="$$(ocamlc -version 2>/dev/null)"; \
	if [ "$$have" != "$(OCAML_PINNED_VERSION)" ]; then \
		echo "ERROR: OCaml $(OCAML_PINNED_VERSION) is required (found '$$have')." >&2; \
		echo "       The vendored blob's runtime ABI is version-locked to it; building or" >&2; \
		echo "       linking against a different OCaml is unsupported. Select OCaml" >&2; \
		echo "       $(OCAML_PINNED_VERSION) (an opam switch, or a pinned Homebrew formula) —" >&2; \
		echo "       see vendor/README.md — then retry." >&2; \
		exit 1; \
	fi; \
	echo "OCaml toolchain OK: $$have (pinned $(OCAML_PINNED_VERSION))"

# The rendered Unison reference manual that ships in the .app bundle as
# Help → "Unison File Synchronizer Manual". Generated from upstream's
# `doc/unison-manual.tex` via hevea (the same TeX→HTML converter
# upstream uses). See `make vendor-manual` and `vendor/README.md`.
# Self-contained single-file HTML with inlined CSS — no companion assets.
VENDORED_MANUAL := $(CURDIR)/vendor/unison-manual-$(UNISON_VERSION).html
UPSTREAM_MANUAL_TEX := $(UNISON_SRC)/../doc/unison-manual.tex

# `BLOB ?=` lets a developer override on the command line:
#   make build BLOB=$(UNISON_SRC)/unison-blob.o
# …to rebuild from source instead of using the vendored copy.
BLOB ?= $(VENDORED_BLOB)
# Exported so `xcodegen generate` bakes the resolved path into the
# generated project's BLOB build setting (project.yml: `BLOB: ${BLOB}`).
# Without this, only `make build` (which passes BLOB= on the xcodebuild
# command line) links the OCaml engine — a bare `xcodebuild` or an
# Xcode.app build would silently produce an unlinked, broken bundle.
# OCAMLLIBDIR and STRIPPED_ASMRUN_DIR are exported for the same reason.
export BLOB

# Stripped copy of libasmrun.a without main.n.o, so the linker doesn't see
# two definitions of `_main` (one from libasmrun, one synthesized by Swift).
LIBDIR := $(CURDIR)/.build/ocamllibs
STRIPPED_ASMRUN := $(LIBDIR)/libasmrun_nomain.a
export STRIPPED_ASMRUN_DIR := $(LIBDIR)

# The full set of OCaml runtime archives the app links (project.yml OTHER_LDFLAGS:
# -lasmrun_nomain -lthreadsnat -lunixnat -lcamlstrnat). The last three link
# straight from $(OCAMLLIBDIR); the first is the stripped copy above. All four
# must be genuinely built for the deployment target (see SF7 below); the runtime
# archives are the OCaml install's own (built by `ocaml/setup-ocaml`), so this is
# a property of HOW OCaml was built, verified by verify-runtime-minos.
RUNTIME_ARCHIVES := $(STRIPPED_ASMRUN) \
	$(OCAMLLIBDIR)/libthreadsnat.a \
	$(OCAMLLIBDIR)/libunixnat.a \
	$(OCAMLLIBDIR)/libcamlstrnat.a

# The app's macOS deployment target, read from the single source of truth
# (project.yml). verify-runtime-minos asserts the OCaml runtime was built for it.
DEPLOY_TARGET := $(shell awk '/deploymentTarget:/{f=1} f&&/macOS:/{gsub(/[" ]/,""); split($$0,a,":"); print a[2]; exit}' project.yml)

XCODEPROJ := unison-ui-mac.xcodeproj
DERIVED := $(CURDIR)/.build/derived
BUILT_APP := $(DERIVED)/Build/Products/$(CONFIG)/unison-ui-mac.app
BUILT_BIN := $(BUILT_APP)/Contents/MacOS/unison-ui-mac

.PHONY: all
all: build

# ----- Local fork patches applied to upstream Unison checkout -----
#
# This project maintains a small set of local patches on top of vanilla
# Unison — they add Callback registrations to `src/uimacbridge.ml` for
# entry points that the upstream uimac UI doesn't expose. The patches
# live in `patches/` here; we apply them idempotently before each blob
# build. Detected by grepping the source for the registered name — if
# the callback is missing, apply; otherwise skip.
#
# Patches stay LOCAL — never proposed back to bcpierce00/unison, per
# this project's LLM-usage stance (Unison's CONTRIBUTING.md bans
# LLM-generated contributions).
#
# Only meaningful when an upstream clone is present; the vendored
# blob already has these patches baked in.
.PHONY: apply-patches
# Complete-state patch detection lives in scripts/apply-unison-patches.sh:
# per patch it forward-dry-runs (apply), else reverse-dry-runs (already
# applied), else fails loudly (partial/incompatible). A single grep on one
# symbol can't tell a half-applied multi-file patch from a fully applied one.
apply-patches:
	@scripts/apply-unison-patches.sh "$(UNISON_SRC)/.." "$(CURDIR)/patches"

# ----- OCaml blob -----
#
# The vendored blob is a checked-in file; no make rule attempts to
# rebuild it during a normal `make build`. The upstream-rebuild rule
# is gated on `BLOB == UPSTREAM_BLOB` so users haven't checked out
# upstream Unison don't trip an unwanted `make macui` invocation.
.PHONY: blob
blob: $(BLOB)

ifeq ($(BLOB),$(UPSTREAM_BLOB))
$(BLOB): apply-patches
	$(MAKE) -C $(UNISON_SRC)/.. macui
endif

# Maintainer target: rebuild the vendored blob from upstream + patches
# and stage it for commit. Run this when bumping upstream Unison or
# adjusting our patch set. Leaves the working tree with a modified
# `vendor/unison-blob-<version>-<arch>.o` ready for `git add`.
#
# Always uses $(UPSTREAM_BLOB) as the source — overriding BLOB= would
# defeat the purpose of vendoring.
.PHONY: vendor-blob
vendor-blob: check-ocaml-version
	@if [ ! -d "$(UNISON_SRC)" ]; then \
		echo "ERROR: upstream Unison checkout not found at $(UNISON_SRC)" >&2; \
		echo "Clone it first:" >&2; \
		echo "  git clone https://github.com/bcpierce00/unison.git $$(dirname $(UNISON_SRC))" >&2; \
		exit 1; \
	fi
	$(MAKE) apply-patches
	# Build ONLY the OCaml core object (unison-blob.o), not upstream's
	# reference Unison.app. Patch 0004 makes uimacbridge.ml reference the
	# app-side C reaper symbols (unison_bridge_register_child/…), which the
	# blob links against fine (undefined here, resolved when OUR app links)
	# but which upstream's own `macui` app link cannot resolve. We only need
	# the blob object, so build that target directly via Makefile.OCaml.
	cd $(UNISON_SRC) && $(MAKE) Makefile.cfg && $(MAKE) -f Makefile.OCaml unison-blob.o
	@mkdir -p $(dir $(VENDORED_BLOB))
	cp $(UPSTREAM_BLOB) $(VENDORED_BLOB)
	@echo ""
	@echo "Vendored: $(VENDORED_BLOB)"
	@echo "Upstream commit: $$(cd $(UNISON_SRC)/.. && git rev-parse HEAD)"
	@echo "Don't forget to:"
	@echo "  - update vendor/README.md with the new commit hash + checksum"
	@echo "  - re-run \`make vendor-manual\` if upstream's doc/ changed"
	@echo "  - git add vendor/ && git commit"

# Maintainer target: render upstream's TeX manual to HTML via hevea and
# stage it for commit. Run this alongside `vendor-blob` whenever the
# upstream version bumps so the bundled manual matches the embedded
# Unison engine. Hevea is upstream's own TeX→HTML toolchain (see their
# doc/Makefile's HEVEA_FOUND check), so this produces the same output
# upstream would. Self-contained single-file HTML with inlined CSS.
#
# Hevea emits a cosmetic warning about a missing .htoc file (which
# would give a clickable TOC); the body content is complete without it,
# so we don't bother running pdflatex first to generate one.
.PHONY: vendor-manual
vendor-manual:
	@if [ ! -f "$(UPSTREAM_MANUAL_TEX)" ]; then \
		echo "ERROR: upstream manual not found at $(UPSTREAM_MANUAL_TEX)" >&2; \
		echo "Clone upstream Unison first (see vendor-blob)." >&2; \
		exit 1; \
	fi
	@if ! command -v hevea >/dev/null 2>&1; then \
		echo "ERROR: hevea not installed. Install with:" >&2; \
		echo "  brew install hevea" >&2; \
		exit 1; \
	fi
	@mkdir -p $(dir $(VENDORED_MANUAL))
	cd $(dir $(UPSTREAM_MANUAL_TEX)) && hevea -fix unison-manual.tex
	cp $(dir $(UPSTREAM_MANUAL_TEX))unison-manual.html $(VENDORED_MANUAL)
	@echo ""
	@echo "Vendored: $(VENDORED_MANUAL) ($$(wc -c < $(VENDORED_MANUAL)) bytes)"
	@echo "Upstream commit: $$(cd $(UNISON_SRC)/.. && git rev-parse HEAD)"
	@echo "Hevea version:   $$(hevea -version 2>&1 | head -1)"
	@echo "Don't forget to:"
	@echo "  - update vendor/README.md with the new commit hash"
	@echo "  - git add vendor/ && git commit"

# ----- OCaml runtime built for the deployment target (SF7) -----
# The OCaml runtime archives the app links (libasmrun.a, libthreadsnat.a,
# libunixnat.a, libcamlstrnat.a from `ocamlc -where`) come from the OCaml install
# itself. When OCaml is built on a newer macOS host (Release runs on macOS 26)
# WITHOUT a deployment target, its runtime objects are compiled with that host's
# minos — so linking the app for macOS 15 emits ~470 "was built for newer macOS
# version" warnings, and, worse, any post-15 API the runtime references is bound
# as a STRONG symbol against the newer SDK rather than weak-imported. That is a
# real load-time / runtime hazard on the baseline OS, not a cosmetic warning.
#
# The fix is to build OCaml itself for the deployment target: the CI/release
# workflows export MACOSX_DEPLOYMENT_TARGET (from project.yml) BEFORE
# `ocaml/setup-ocaml`, so the compiler evaluates availability at the target and
# emits genuinely minos-15 runtime objects (SDK stays the host's — an honest
# "built against SDK 26, deploys to 15"). We do NOT rewrite LC_BUILD_VERSION
# afterward: relabelling would only falsify the metadata the gates then trust.
# `verify-runtime-minos` asserts the runtime really was built for the target, and
# a macOS-15 launch smoke of the release-built app exercises the exact bytes.

# Stripped copy of libasmrun.a WITHOUT main.n.o, so the linker doesn't see two
# definitions of `_main` (one from libasmrun, one synthesized by Swift). This is a
# pure `ar` repackage — no recompile, no metadata rewrite — so the stripped copy
# inherits libasmrun.a's real deployment target unchanged.
$(STRIPPED_ASMRUN): $(OCAMLLIBDIR)/libasmrun.a
	@mkdir -p $(LIBDIR)/extract
	cd $(LIBDIR)/extract && ar x $(OCAMLLIBDIR)/libasmrun.a && rm -f main.n.o
	ar rcs $@ $(LIBDIR)/extract/*.o
	rm -rf $(LIBDIR)/extract

# Deterministic SF7 gate: every runtime archive the app links was genuinely built
# for the deployment target (checks the archives directly, no app build required).
# Fails loudly if OCaml was built for a different macOS — the condition that both
# produces the deployment-version warnings and leaves post-15 references strongly
# bound. Unlike a relabel, this asserts a property of the actual compiled bytes.
.PHONY: verify-runtime-minos
verify-runtime-minos: $(STRIPPED_ASMRUN)
	@test -n "$(DEPLOY_TARGET)" || { echo "error: could not read deploymentTarget from project.yml"; exit 1; }
	@fail=0; \
	for a in $(RUNTIME_ARCHIVES); do \
		test -f "$$a" || { echo "FAIL: runtime archive not found: $$a" >&2; fail=1; continue; }; \
		vers="$$(otool -l "$$a" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $$2; f=0}' | sort -u | paste -sd, -)"; \
		if [ "$$vers" != "$(DEPLOY_TARGET)" ]; then \
			echo "FAIL: $$(basename $$a) built for macOS '$$vers' (want $(DEPLOY_TARGET)) — build OCaml with MACOSX_DEPLOYMENT_TARGET=$(DEPLOY_TARGET)" >&2; fail=1; \
		else \
			echo "OK:   $$(basename $$a) built for macOS $(DEPLOY_TARGET)"; \
		fi; \
	done; \
	test $$fail -eq 0

# ----- Generate the Xcode project + Resources/Info.plist (from project.yml) --
#
# project.yml is the SOLE human-maintained source of truth. The .xcodeproj and
# Resources/Info.plist are generated artifacts (both gitignored) and must NOT be
# committed. `scripts/generate-project.sh` is the single generation authority:
# it enforces the pinned XcodeGen (scripts/install-xcodegen.sh) and rewrites the
# project + plist from project.yml on every run — so a stale local copy can
# never survive as build input (proven by `make check-generate-contract`). It
# preserves the project.pbxproj mtime on a no-op so incremental builds aren't
# perturbed. Every build/test/open path depends on `generate`. The exported
# vars above (UNISON_VERSION, BLOB, OCAMLLIBDIR, STRIPPED_ASMRUN_DIR) are what
# xcodegen substitutes into project.yml.
#
# The pinned XcodeGen lives in an ignored, repository-local path (.tools/…, not
# on PATH) so a global/Homebrew xcodegen can't shadow it. generate-project.sh
# validates that install COMPLETELY (binary version + presets) on every run and
# installs/repairs it (no sudo) if missing or incomplete, failing closed.
.PHONY: generate xcodeproj
generate:
	./scripts/generate-project.sh
# Back-compat alias for the previous target name.
xcodeproj: generate

# (Re)install the pinned, checksum-verified XcodeGen into .tools/ (single version
# authority: scripts/install-xcodegen.sh).
.PHONY: install-xcodegen
install-xcodegen:
	./scripts/install-xcodegen.sh

# ----- Local code-signing identity (TCC-stable dev builds) -----
# An ad-hoc signature ("-", the project.yml default) carries no certificate,
# so macOS derives the app's TCC "designated requirement" from its cdhash —
# which changes on every rebuild. Each freshly built app then looks brand new
# to TCC and re-prompts for every permission (Notifications, Documents access,
# ...) on launch. Signing a Debug build with a real Apple Development
# certificate instead yields a stable requirement (bundle id + certificate
# leaf), so a permission you grant once survives all later rebuilds.
#
# scripts/resolve-signing.sh resolves the identity and team TOGETHER from a
# single valid identity record (never two independent lookups that could refer
# to different certs), and falls back to ad-hoc on any ambiguity. Policy:
#   - Debug / `make test`: stable Apple Development signature when a complete,
#     self-consistent identity/team pair is available; else ad-hoc.
#   - CI (any config): ad-hoc (no cert on runners).
#   - Every Release build: ad-hoc, even with an override present — a personal
#     dev cert (expires, not valid for distribution) must never touch a Release
#     artifact. The local `make install` path ships that ad-hoc signature
#     (`codesign --sign -`); the release pipeline builds ad-hoc here and then
#     RE-SIGNS with a Developer ID identity and notarizes in a dedicated step
#     (release.yml), so this build step never needs a distribution cert.
# Manual overrides (Debug/`make test` only): `SIGN_IDENTITY=-` forces ad-hoc; a
# custom identity must be supplied together with a matching `DEV_TEAM`, and the
# pair is VERIFIED against a single valid keychain record before use (an
# unverifiable/mismatched pair falls back to ad-hoc).
#
# SAFETY: overrides and CONFIG reach the resolver through the ENVIRONMENT (the
# `export` below), never interpolated into recipe text, and the recipe reads the
# resolver's two-line output with plain line parsing — no `eval`. So an identity
# name containing spaces, apostrophes, `$`, `;`, quotes, etc. can neither break
# parsing nor execute during the build. Auto-detected values are a hex hash + an
# alnum team (no metacharacters at all); a cert name is only ever used when the
# operator supplies it as a verified manual override. `select-signing.sh` turns a
# resolver error or malformed output into a hard build failure (distinct from the
# resolver's normal policy-driven ad-hoc fallback). Note: values passed as a
# `make` command-line assignment (`make build SIGN_IDENTITY=…`) are subject to
# make's own `$(…)` expansion — an inherent make behavior, not specific to
# signing; set overrides via the environment if they contain make metacharacters.
#
# NOTE: this covers Makefile-driven `build`/`test` only. A direct Xcode.app
# build still uses the generated project's ad-hoc default. Persistence of a
# TCC grant holds across repeated identically-signed Debug rebuilds (cdhash may
# change, the designated requirement does not); it is NOT guaranteed across
# alternating Debug (dev-signed) and Release (ad-hoc) launches of the same
# bundle id, which present different requirements.
export SIGN_IDENTITY
export DEV_TEAM
export CONFIG

# ----- Build via xcodebuild -----
.PHONY: build
build: check-ocaml-version $(BLOB) $(STRIPPED_ASMRUN) verify-runtime-minos generate
	@vals="$$(./scripts/select-signing.sh)" || exit $$?; \
	id="$$(printf '%s\n' "$$vals" | sed -n '1p')"; \
	team="$$(printf '%s\n' "$$vals" | sed -n '2p')"; \
	xcodebuild \
		-project $(XCODEPROJ) \
		-scheme unison-ui-mac \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) \
		OCAMLLIBDIR=$(OCAMLLIBDIR) \
		UNISON_SRC=$(UNISON_SRC) \
		STRIPPED_ASMRUN_DIR=$(STRIPPED_ASMRUN_DIR) \
		BLOB=$(BLOB) \
		CODE_SIGN_IDENTITY="$$id" $${team:+DEVELOPMENT_TEAM="$$team"} \
		build

.PHONY: run
run: build
	$(BUILT_BIN) $(RUNARGS)

# Tests always run against the Debug configuration. Debug builds carry
# `assert()` / preconditions that catch bugs which Release would optimize
# away, and they build faster on iteration. The user-facing CONFIG knob
# doesn't apply here — `make test` and `make test CONFIG=Release` behave
# identically (signing is always resolved with CONFIG=Debug here).
.PHONY: test
test: check-ocaml-version $(BLOB) $(STRIPPED_ASMRUN) verify-runtime-minos generate
	@vals="$$(CONFIG=Debug ./scripts/select-signing.sh)" || exit $$?; \
	id="$$(printf '%s\n' "$$vals" | sed -n '1p')"; \
	team="$$(printf '%s\n' "$$vals" | sed -n '2p')"; \
	xcodebuild \
		-project $(XCODEPROJ) \
		-scheme unison-ui-mac \
		-configuration Debug \
		-derivedDataPath $(DERIVED) \
		-destination 'platform=macOS' \
		OCAMLLIBDIR=$(OCAMLLIBDIR) \
		UNISON_SRC=$(UNISON_SRC) \
		STRIPPED_ASMRUN_DIR=$(STRIPPED_ASMRUN_DIR) \
		BLOB=$(BLOB) \
		CODE_SIGN_IDENTITY="$$id" $${team:+DEVELOPMENT_TEAM="$$team"} \
		test

.PHONY: app
app: build
	open $(BUILT_APP) $(if $(RUNARGS),--args $(RUNARGS),)

# Deterministic matrix test for the code-signing resolver (no keychain / no
# xcodebuild needed). Exercises Debug/Release, CI, multiple identities, and the
# manual-override contract via the resolver's SIGN_RESOLVER_*_CMD test seams.
.PHONY: check-signing
check-signing:
	@./scripts/test-resolve-signing.sh

# Deterministic test for the appcast signature verifier (no Xcode / no network /
# no Sparkle tools needed). Runs verify-appcast-signatures.sh against committed
# fixtures to lock the per-enclosure EdDSA-signature check — including the
# regression case where a signed release-notes link must not mask an unsigned
# enclosure.
.PHONY: check-appcast
check-appcast:
	@./scripts/test-sparkle-appcast.sh

# sparkle-appcast.sh output-path resolution: it must validate the appcast
# generate_appcast actually wrote, for the separated AND joined -o/--output-path
# forms. Pure shell (stubs generate_appcast; no Sparkle tools / no network).
.PHONY: check-sparkle-output-path
check-sparkle-output-path:
	@./scripts/test-sparkle-output-path.sh

# Deterministic guard tests for sign-app.sh (no Xcode / no cert / no network):
# the fail-fast presence + identity guards against a fake bundle skeleton.
.PHONY: check-sign-app
check-sign-app:
	@./scripts/test-sign-app.sh

# install.sh hardening tests (SF8–SF10): Release-only selection, staged-then-swap
# install with rollback, and verified quarantine strip. Pure shell (no
# Xcode/OCaml/sudo), via install.sh's test seams.
.PHONY: check-install
check-install:
	@./scripts/test-install.sh

# SF7 bundle-floor verifier test (clang fixtures only, no Xcode/OCaml): exercises
# verify-bundle-minos.sh's two-tier rule and its fail-closed cases.
.PHONY: check-bundle-minos
check-bundle-minos:
	@./scripts/test-verify-bundle-minos.sh

# SF7: assert the BUILT bundle's Mach-O deployment floors (checks the finished
# product, complementing verify-runtime-minos which checks the input archives).
# Runs against the current CONFIG's build output; CI invokes it after `make build`
# and, for the exact packaged/signed artifact, against the unpacked .app.
.PHONY: verify-bundle-minos
verify-bundle-minos:
	./scripts/verify-bundle-minos.sh $(BUILT_APP)

# Release-notes markdown -> Sparkle "What's New" HTML fragment converter test
# (Python stdlib only, no network / no Sparkle tools).
PYTHON ?= python3
.PHONY: check-release-notes
check-release-notes:
	@$(PYTHON) ./scripts/test-release-notes-to-html.py

# Cryptographic appcast verifier test. Exercises verify-appcast.py against the
# REAL pinned sign_update (Sparkle's own verifier) with a THROWAWAY key: a signed
# feed + archive pass; a tampered archive, a poisoned feed, the wrong key, and an
# out-of-prefix enclosure URL all fail closed. Requires SPARKLE_BIN (the
# checksum-pinned Sparkle tools bin/); CI fetches it. Fails — never skips — if
# SPARKLE_BIN is absent, because this is a release gate.
.PHONY: check-verify-appcast
check-verify-appcast:
	@$(PYTHON) ./scripts/test-verify-appcast.py

# Generation-contract regression test: proves `make generate` deterministically
# creates an absent Resources/Info.plist and REPLACES a stale one with the
# project.yml values (an old ignored local copy can never survive as build
# input). Requires the pinned XcodeGen (the generation step enforces it).
.PHONY: check-generate-contract
check-generate-contract:
	./scripts/test-generate-project.sh

# Fail-closed check of the critical Sparkle/bundle keys in the GENERATED plist
# against project.yml (the source of truth). Generates first, then verifies.
# The stronger built-app check (verify-plist-keys.sh --app) runs in CI after the
# build and on the release path against the signed bundle.
.PHONY: check-plist-keys
check-plist-keys: generate
	./scripts/verify-plist-keys.sh --generated Resources/Info.plist

# Independent security-policy assertions on the generated plist (hard-coded, not
# read from project.yml) — catches a weakened project.yml that verify-plist-keys
# would still pass. The built-app policy check runs in CI/release.
.PHONY: check-plist-policy
check-plist-policy: generate
	./scripts/verify-plist-policy.sh --generated Resources/Info.plist

# Regression: a repository-local XcodeGen with the right binary but missing
# SettingPresets must be detected and repaired before generation (a missing-
# presets install silently emits a different project).
.PHONY: check-xcodegen-install
check-xcodegen-install:
	./scripts/test-xcodegen-install.sh

# `make install` — the end-to-end installation flow. Always builds the
# Release configuration (regardless of the user's CONFIG setting — a
# user-facing install wants the optimized binary, not a Debug build with
# assertions and a multi-megabyte .debug.dylib sidecar), then hands off
# to install.sh, which ad-hoc-signs the bundle, copies it to
# /Applications, clears the quarantine attribute, and opens the
# installed copy. This is the supported user path; the manual two-line
# equivalent in INSTALL.md does the same thing piece by piece.
#
# Pass INSTALL_ARGS=--no-launch (or any other install.sh flag) to
# override the default behavior, e.g.:
#     make install INSTALL_ARGS=--no-launch
#     make install INSTALL_ARGS="--dest $$HOME/Applications"
.PHONY: install
install:
	$(MAKE) build CONFIG=Release
	./install.sh $(INSTALL_ARGS)

# Ad-hoc leak check via `leaks(1)`. Launches the app, waits a few
# seconds for AppDelegate to spin up + show the picker, runs the
# system leaks tool against the live PID, and prints its summary.
# Intended for hand-running before a release — not part of `make test`.
#
# Caveats:
# - macOS may suppress non-debug leaks unless the app is signed with
#   `get-task-allow` entitlements (already true for our Debug build).
# - Some leaks reported here are inside OCaml's runtime (unison-blob.o)
#   or in linked Apple frameworks; not all are actionable on our side.
# - The app is left running after the check — close it manually or
#   pass STOP_AFTER_LEAKS=1 to kill it.
.PHONY: leaks
leaks: build
	@echo "Launching unison-ui-mac for leak check…"
	@open $(BUILT_APP)
	@sleep 3
	@pid="$$(pgrep -fn 'unison-ui-mac.app/Contents/MacOS/unison-ui-mac' || pgrep -fn unison-ui-mac)"; \
		if [ -z "$$pid" ]; then \
			echo "ERROR: no unison-ui-mac process found"; exit 1; \
		fi; \
		echo "PID: $$pid"; \
		leaks $$pid; rc=$$?; \
		if [ "$$STOP_AFTER_LEAKS" = "1" ]; then kill $$pid; fi; \
		exit $$rc

.PHONY: open
open: generate
	open $(XCODEPROJ)

.PHONY: clean
clean:
	xcodebuild -project $(XCODEPROJ) clean -derivedDataPath $(DERIVED) 2>/dev/null || true
	rm -rf .build

.PHONY: distclean
distclean: clean
	rm -rf $(XCODEPROJ)
	rm -f Resources/Info.plist   # generated (gitignored) — regenerated by `make generate`

.PHONY: print-config
print-config:
	@echo UNISON_SRC=$(UNISON_SRC)
	@echo OCAMLLIBDIR=$(OCAMLLIBDIR)
	@echo BLOB=$(BLOB)
	@test -f $(BLOB) && echo "blob: present" || echo "blob: MISSING"
	@echo STRIPPED_ASMRUN=$(STRIPPED_ASMRUN)
	@test -f $(STRIPPED_ASMRUN) && echo "stripped asmrun: present" || echo "stripped asmrun: MISSING"
	@echo XCODEPROJ=$(XCODEPROJ)
	@test -d $(XCODEPROJ) && echo "xcodeproj: present" || echo "xcodeproj: MISSING"
