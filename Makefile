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
ARCH := $(shell uname -m)
VENDORED_BLOB := $(CURDIR)/vendor/unison-blob-$(UNISON_VERSION)-$(ARCH).o
UPSTREAM_BLOB := $(UNISON_SRC)/unison-blob.o

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
apply-patches:
	@if [ ! -f "$(UNISON_SRC)/uimacbridge.ml" ]; then \
		echo "No upstream Unison checkout at $(UNISON_SRC) — skipping patch apply."; \
		echo "(Vendored blob in vendor/ already has the patches baked in.)"; \
		exit 0; \
	fi; \
	if ! grep -q 'Callback.register "abortAll"' $(UNISON_SRC)/uimacbridge.ml; then \
		echo "Applying patch: 0001-uimacbridge-register-abortAll.patch"; \
		cd $(UNISON_SRC)/.. && patch -p1 < $(CURDIR)/patches/0001-uimacbridge-register-abortAll.patch; \
	else \
		echo "Local fork patches already applied to $(UNISON_SRC)/uimacbridge.ml"; \
	fi

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
vendor-blob:
	@if [ ! -d "$(UNISON_SRC)" ]; then \
		echo "ERROR: upstream Unison checkout not found at $(UNISON_SRC)" >&2; \
		echo "Clone it first:" >&2; \
		echo "  git clone https://github.com/bcpierce00/unison.git $$(dirname $(UNISON_SRC))" >&2; \
		exit 1; \
	fi
	$(MAKE) apply-patches
	$(MAKE) -C $(UNISON_SRC)/.. macui
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

# ----- Stripped libasmrun -----
$(STRIPPED_ASMRUN): $(OCAMLLIBDIR)/libasmrun.a
	@mkdir -p $(LIBDIR)/extract
	cd $(LIBDIR)/extract && ar x $(OCAMLLIBDIR)/libasmrun.a && rm -f main.n.o
	ar rcs $@ $(LIBDIR)/extract/*.o
	rm -rf $(LIBDIR)/extract

# ----- Xcode project (regenerate from project.yml + source list) -----
#
# xcodegen reads project.yml plus the directory globs in it (Sources/App,
# Sources/Bridge, Tests). The project file needs to regenerate when:
#   1. project.yml itself changes, OR
#   2. a source file is ADDED, REMOVED, or RENAMED (changes the glob result).
#
# Make doesn't watch glob results directly. The trick: depend on the
# source DIRECTORIES rather than the file list. POSIX advances a
# directory's mtime when an entry is added or removed, but NOT on
# file content edits. So:
#   - Touch any .swift file       → no regen (Xcode handles content via
#                                   its own dep system).
#   - Add / remove / rename a file → dir mtime advances → manifest regen
#                                   → if list actually changed,
#                                     mtime moves forward → xcodegen runs.
#
# The manifest content check (cmp -s) means a no-op dir touch (e.g.
# `touch Sources/App`) doesn't trigger a spurious regen — the manifest
# only updates its mtime when the file list materially differs.
SOURCE_DIRS := Sources/App Sources/Bridge Tests
SOURCES_MANIFEST := .build/sources.manifest

$(SOURCES_MANIFEST): $(SOURCE_DIRS)
	@mkdir -p $(@D)
	@find $(SOURCE_DIRS) -type f \( -name '*.swift' -o -name '*.c' -o -name '*.h' \) | sort > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then \
		rm $@.tmp; \
		touch $@; \
	else \
		mv $@.tmp $@; \
		echo "Source list changed → xcodeproj will regenerate"; \
	fi

.PHONY: xcodeproj
xcodeproj: $(XCODEPROJ)

$(XCODEPROJ): project.yml $(SOURCES_MANIFEST)
	xcodegen generate

# ----- Build via xcodebuild -----
.PHONY: build
build: $(BLOB) $(STRIPPED_ASMRUN) $(XCODEPROJ)
	xcodebuild \
		-project $(XCODEPROJ) \
		-scheme unison-ui-mac \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) \
		OCAMLLIBDIR=$(OCAMLLIBDIR) \
		UNISON_SRC=$(UNISON_SRC) \
		STRIPPED_ASMRUN_DIR=$(STRIPPED_ASMRUN_DIR) \
		BLOB=$(BLOB) \
		build

.PHONY: run
run: build
	$(BUILT_BIN) $(RUNARGS)

# Tests always run against the Debug configuration. Debug builds carry
# `assert()` / preconditions that catch bugs which Release would optimize
# away, and they build faster on iteration. The user-facing CONFIG knob
# doesn't apply here — `make test` and `make test CONFIG=Release` behave
# identically.
.PHONY: test
test: $(BLOB) $(STRIPPED_ASMRUN) $(XCODEPROJ)
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
		test

.PHONY: app
app: build
	open $(BUILT_APP) $(if $(RUNARGS),--args $(RUNARGS),)

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
open: $(XCODEPROJ)
	open $(XCODEPROJ)

.PHONY: clean
clean:
	xcodebuild -project $(XCODEPROJ) clean -derivedDataPath $(DERIVED) 2>/dev/null || true
	rm -rf .build

.PHONY: distclean
distclean: clean
	rm -rf $(XCODEPROJ)

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
