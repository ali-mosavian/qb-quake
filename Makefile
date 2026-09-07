##
## qb-qrender -- Quake BSP renderer in BASIC, built for real-mode DOS.
##
## The compiler and linker are DOS programs, so every module compile shells
## out to tools/bc.sh (BASIC) or tools/bcc-qr.sh (this project's own C
## ports), each launching its OWN isolated DOSBox-X -- same idea as
## tools/native/Makefile's C/asm side, so that `make -jN` actually
## parallelises instead of serialising through one shared build.bat session
## the way tools/dosbox.sh's own build target still does. LINK is the one
## step that stays single: it needs every object at once, via
## tools/link-qr.sh.
##
## vbd only, on purpose -- see tools/bc.sh's own note on why pds/qb45 (kept
## below only as documented failure evidence) do not need this treatment.
##
## NATIVE_UGL must already exist (build it first: make -f tools/native/Makefile).
## This Makefile only reads it, the same restraint tools/native/Makefile
## takes with the mgl source tree itself.
##

MGL        ?= $(HOME)/work/badlogic/mgl
TOOLCHAINS ?= $(HOME)/work/other/d32x/toolchains
DOSBOX_BIN ?=
MAP        ?= dm3ish.bsp
TIMEOUT    ?= 600
BUILD      ?= $(CURDIR)/build/vbd
NATIVE_UGL ?= $(CURDIR)/build/native-mgl/UGLV.LIB

export MGL TOOLCHAINS DOSBOX_BIN TIMEOUT

BC     := $(CURDIR)/tools/bc.sh
BCC_QR := $(CURDIR)/tools/bcc-qr.sh
LINKQR := $(CURDIR)/tools/link-qr.sh

# Sources sit in one directory per subsystem. Objects stay FLAT in
# $(BUILD) -- LINK takes module names, not paths, so the layout is a
# host-side concern only and basenames must therefore stay unique across
# the tree. vpath is what lets the pattern rules below keep matching on
# the bare name.
SRC_DIRS := src/host src/render src/game src/qgl src/qgl/b8
vpath %.bas $(SRC_DIRS)
vpath %.c   $(SRC_DIRS)
vpath %.asm $(SRC_DIRS)

# main first, unconditionally -- it carries the module-level main code,
# and the link step needs it named first in the object list. NOT sorted:
# sort would alphabetise main to the middle of the list.
BAS_SRC  := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.bas))
BAS_MODS := main $(filter-out main,$(basename $(notdir $(BAS_SRC))))
HDRS     := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.bi))

C_SRC  := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.c))
C_MODS := $(basename $(notdir $(C_SRC)))
C_HDRS := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.h))

# This project's own assembly -- hot loops that are ours, not uGL's, and
# so have no business living in mgl's tree. Assembled on the host: jwasm
# needs no DOS, unlike BC and BCC.
ASM_SRC  := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.asm))
ASM_MODS := $(basename $(notdir $(ASM_SRC)))
ASM_INC  := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.inc))
JWASM    := $(TOOLCHAINS)/native/bin/jwasm

BAS_OBJS := $(addprefix $(BUILD)/,$(addsuffix .obj,$(BAS_MODS)))
C_OBJS   := $(addprefix $(BUILD)/,$(addsuffix .obj,$(C_MODS)))
ASM_OBJS := $(addprefix $(BUILD)/,$(addsuffix .obj,$(ASM_MODS)))

DATA := data/stuff.ini data/base.dat
## Preprocessed textures. The renderer blits these instead of resampling and
## colour-matching the miptex lump at every launch; the raw atlas stands in
## for the whole set as far as make is concerned.
ASSETS := data/assets/assets.zip
ASSET_FILES := $(wildcard data/assets/*)
EXE  := $(BUILD)/qrender.exe

.PHONY: all build run viz qb45 pds evidence assets test clean help

all: build                      ## build the renderer (default)
build: $(EXE)
assets: $(ASSETS)         ## regenerate the preprocessed textures

$(ASSETS): data/$(MAP) data/base.dat tools/mkassets.py
	@python3 tools/mkassets.py data/$(MAP) data/base.dat data/assets

$(BUILD):
	mkdir -p $(BUILD)

# Every BASIC module depends on every .bi: BC's own $include resolution
# cannot say in advance which subset a given module actually needs
# without parsing it, and copying the small ones costs nothing to over-
# depend on -- tools/bc.sh already copies all of them per invocation.
$(BUILD)/%.obj: %.bas $(HDRS) | $(BUILD)
	$(BC) $< $@

# qrender's own C ports (r_walk.c, sb_build.c, pl_trace.c, r_span.c),
# NOT mgl's -- see tools/bcc-qr.sh's own note on why that is a separate
# script from tools/bcc.sh rather than a shared one with more flags.
$(BUILD)/%.obj: %.c $(C_HDRS) | $(BUILD)
	$(BCC_QR) $< $@

# On every .inc, for the same reason the BASIC rule takes every .bi:
# qgl.inc carries the surface kinds and the struct layouts, so an edit
# there changes what these objects mean while leaving every .asm file
# untouched. Without the dependency the stale objects survive, LINK is
# happy, and the EXE runs the old constants against the new BASIC
# declarations. tools/depcheck.sh is the regression.
$(BUILD)/%.obj: %.asm $(ASM_INC) | $(BUILD)
	# __BASIC__: this build links BASIC's runtime, so qgl may call
	# B$$SETM to reclaim far-heap memory. The qgl test suite does not
	# define it and links free-standing.
	$(JWASM) -c -Cp -Zg -omf -D__BASIC__=1 -I$(CURDIR)/src/qgl -Fo$@ $<

$(BUILD)/stuff.ini: data/stuff.ini | $(BUILD)
	cp $< $@

$(BUILD)/base.dat: data/base.dat | $(BUILD)
	cp $< $@

# qgl_txt_load wants a loose file beside the exe, not a PACK member --
# see txt.asm's own note that this is mkfont.py's job, not INT 21h's.
$(BUILD)/FONT.FNT: data/base.dat tools/mkfont.py | $(BUILD)
	@python3 tools/mkfont.py data/base.dat font/4x6.fnt $@

$(BUILD)/UGLV.LIB: $(NATIVE_UGL) | $(BUILD)
	cp $< $@

# Copy the whole directory rather than naming extensions, which is how
# the .bld lumps silently failed to stage the first time this was
# written by hand.
$(BUILD)/.assets-stamp: $(ASSET_FILES) | $(BUILD)
	cp -R data/assets/* $(BUILD)/
	touch $@

$(EXE): $(BAS_OBJS) $(C_OBJS) $(ASM_OBJS) $(BUILD)/stuff.ini $(BUILD)/base.dat $(BUILD)/FONT.FNT $(BUILD)/UGLV.LIB $(BUILD)/.assets-stamp
	@python3 tools/qblint.py
	$(LINKQR) $(BUILD) "$(BAS_MODS)" "$(C_MODS) $(ASM_MODS)"

# The native gates, in one target so tools/check.sh and a bare `make
# test` cannot drift apart. ~15s from clean, no DOS toolchain and no
# VBDOS -- which is the point: a failure here is qgl's, not the
# renderer's around it.
test:                           ## lint, header deps, the qgl suite
	@python3 tools/qblint.py
	@sh tools/depcheck.sh
	@$(MAKE) --no-print-directory -C src/qgl/test

run: $(EXE)                     ## headless run; 's' screenshots to build/vbd/
	@VBD_OUT=$(BUILD) tools/dosbox.sh run $(MAP)

viz: $(EXE)                     ## windowed run, to watch it live
	@echo "launch: dosbox-x -conf $$(VBD_OUT=$(BUILD) tools/dosbox.sh viz $(MAP))"

## The two failing toolchains are kept as reproducible evidence for the
## README's claim that VBDOS is required rather than merely preferred.
## Unrelated to the parallel path above -- these still go through
## tools/dosbox.sh's own single-session build, which is all they are for.
qb45:                           ## reproduce the QB 4.5 failure
	@tools/dosbox.sh build qb45
pds:                            ## reproduce the PDS 7.1 failure
	@tools/dosbox.sh build pds
evidence: qb45 pds

clean:                          ## drop all build output
	rm -rf build

help:
	@grep -hE '^[a-z0-9]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t 14
