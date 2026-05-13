UNISON_SRC ?= $(HOME)/Documents/Sources/unison/src
OCAMLLIBDIR ?= $(shell ocamlc -where)
CONFIG ?= Debug

export UNISON_SRC
export OCAMLLIBDIR

BLOB := $(UNISON_SRC)/unison-blob.o

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

# ----- OCaml blob (built once by the upstream Unison Makefile) -----
.PHONY: blob
blob: $(BLOB)

$(BLOB):
	$(MAKE) -C $(UNISON_SRC)/.. macui

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
		build

.PHONY: run
run: build
	$(BUILT_BIN) $(RUNARGS)

.PHONY: test
test: $(BLOB) $(STRIPPED_ASMRUN) $(XCODEPROJ)
	xcodebuild \
		-project $(XCODEPROJ) \
		-scheme unison-ui-mac \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) \
		-destination 'platform=macOS' \
		OCAMLLIBDIR=$(OCAMLLIBDIR) \
		UNISON_SRC=$(UNISON_SRC) \
		STRIPPED_ASMRUN_DIR=$(STRIPPED_ASMRUN_DIR) \
		test

.PHONY: app
app: build
	open $(BUILT_APP) $(if $(RUNARGS),--args $(RUNARGS),)

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
