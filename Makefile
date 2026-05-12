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

# ----- Xcode project (regenerate from project.yml) -----
.PHONY: xcodeproj
xcodeproj: $(XCODEPROJ)

$(XCODEPROJ): project.yml
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
