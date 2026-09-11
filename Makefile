##
## qb-qrender -- Quake BSP renderer in BASIC, built for real-mode DOS.
##
## The compiler and linker are DOS programs, so every module compile shells
## out to tools/bc.sh (BASIC) or tools/bcc-qr.sh (this project's own C
## ports), each launching its OWN isolated DOSBox-X, so that `make -jN`
## actually parallelises. LINK is the one step that stays single: it
## needs every object at once, via tools/link-qr.sh.
##
## vbd only, on purpose -- see tools/bc.sh's own note on why pds/qb45 (kept
## below only as documented failure evidence) do not need this treatment.
##

TOOLCHAINS ?= $(HOME)/work/other/d32x/toolchains
DOSBOX_BIN ?=
MAP        ?= dm3ish.bsp
# Quake's own PAK, for the monster mkmdl.py cuts the soldier out of. Not
# in the repo and not redistributable, so a tree without it builds and
# runs without the monster rather than failing -- see the MDL rule below.
PAK        ?= $(HOME)/dos/QUAKE_SW/ID1/PAK0.PAK
MDL        ?= soldier
TIMEOUT    ?= 600
BUILD      ?= $(CURDIR)/build/vbd

# Symbols, on by default. The debug records go in the OBJs and then in
# the tail of the EXE; nothing is loaded at run time, so this costs disk
# and not the conventional memory that is actually scarce here. The
# dosbox-x MCP reads them as the guest EXECs the program, which turns
# "spinning somewhere in LMEM" into a routine, a source file and a line.
# DEBUGINFO=0 for a lean EXE.
DEBUGINFO  ?= 1

export TOOLCHAINS DOSBOX_BIN TIMEOUT DEBUGINFO

BC     := $(CURDIR)/tools/bc.sh
BCC_QR := $(CURDIR)/tools/bcc-qr.sh
LINKQR := $(CURDIR)/tools/link-qr.sh

# Sources sit in one directory per subsystem. Objects stay FLAT in
# $(BUILD) -- LINK takes module names, not paths, so the layout is a
# host-side concern only and basenames must therefore stay unique across
# the tree. vpath is what lets the pattern rules below keep matching on
# the bare name.
SRC_DIRS := src/host src/render src/game src/qgl src/qgl/b8 src/qgl/dct
vpath %.bas $(SRC_DIRS)
vpath %.c   $(SRC_DIRS)
vpath %.asm $(SRC_DIRS)

# main first, unconditionally -- it carries the module-level main code,
# and the link step needs it named first in the object list. NOT sorted:
# sort would alphabetise main to the middle of the list.
BAS_SRC  := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.bas))
BAS_MODS := main $(filter-out main,$(basename $(notdir $(BAS_SRC))))
# The oracles -- -qglcheck, -qgldiff, -qglarr, -qglface -- are 13K of
# code the far heap pays for on every map. ORACLES=1 links them in place
# of qglstub, which refuses their flags; tools/check.sh builds that EXE
# in its own directory for the gate.
ORACLE_MODS := qglchk qgldiff qglarr qglface
ifeq ($(ORACLES),1)
BAS_MODS := $(filter-out qglstub,$(BAS_MODS))
else
BAS_MODS := $(filter-out $(ORACLE_MODS),$(BAS_MODS))
endif
HDRS     := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.bi))

C_SRC  := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.c))
C_MODS := $(basename $(notdir $(C_SRC)))
C_HDRS := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.h))

# This project's own assembly -- hot loops that are ours, not uGL's, and
# so have no business living in mgl's tree. Assembled on the host: jwasm
# needs no DOS, unlike BC and BCC.
ASM_SRC  := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.asm))
# file first: a VFS driver's row lands in a segment file.asm brackets,
# and LINK lays the class out in the order it meets the modules
ASM_MODS := file $(filter-out file,$(basename $(notdir $(ASM_SRC))))
ASM_INC  := $(foreach d,$(SRC_DIRS),$(wildcard $(d)/*.inc))
JWASM    := $(TOOLCHAINS)/native/bin/jwasm

# SERIAL_LOG=1 turns qgl's transcribed LOG lines into a call trace on
# port E9h. Off by default: it is a debugging build, not a slow one to
# leave lying around. _DEBUG_ is mgl's own gate for those macros and is
# set here rather than in qgl.inc, so that header stays mgl's log.inc
# verbatim. Reading the trace needs SERIAL_LOG=1 on the RUN as well --
# see the note on launch() in tools/dosbox.sh.
ifeq ($(SERIAL_LOG),1)
QGL_DEFS := -D_DEBUG_=1
endif

BAS_OBJS := $(addprefix $(BUILD)/,$(addsuffix .obj,$(BAS_MODS)))
C_OBJS   := $(addprefix $(BUILD)/,$(addsuffix .obj,$(C_MODS)))
ASM_OBJS := $(addprefix $(BUILD)/,$(addsuffix .obj,$(ASM_MODS)))

DATA := data/stuff.ini data/base.dat
## Preprocessed textures. The renderer blits these instead of resampling and
## colour-matching the miptex lump at every launch; the raw atlas stands in
## for the whole set as far as make is concerned.
ASSETS := data/assets/assets.zip
# The monster's geometry, vertex frames and skin. host_init loads these by
# name at startup, so a build without them dies in mdl_load -- which is
# how it went missing: data/assets is generated, not tracked, and nothing
# regenerated these. Only reachable with the PAK; wildcard-guarded so a
# tree without it is not a build failure.
MDL_ASSETS := $(if $(wildcard $(PAK)),data/assets/$(MDL).geo data/assets/knight.geo data/assets/dog.geo data/assets/ogre.geo data/assets/demon.geo data/assets/zombie.geo data/assets/wizard.geo data/assets/shambler.geo data/assets/v_shot.geo data/assets/v_shot2.geo data/assets/v_nail.geo data/assets/v_rock.geo data/assets/v_nail2.geo data/assets/v_rock2.geo)
# The status bar's pictures, out of the PAK's gfx.wad.
GFX_ASSETS := $(if $(wildcard $(PAK)),data/assets/sbar.raw data/assets/snd.raw)
# The A* flight path -bench -campath walks. Generated, untracked, and it
# was a ZERO-BYTE file in every clean build: -campath then read nothing,
# stood at the spawn for the whole run, and `check.sh --churn` -- whose
# entire job is to walk it and provoke evictions -- compared two
# identical standing frames and called that a pass.
CAM_ASSETS := data/assets/campath.bin
ASSET_FILES := $(wildcard data/assets/*)
# The maps a run can chain through: each gets its bsp and its own four
# asset files under data/maps/<map>/, staged to $(BUILD)/MAPS/<map>/.
# trigger_changelevel writes NEXT.BAT, GOMAP.BAT copies the next map's
# files over the ones beside the exe and dosbox.sh's run.bat loops.
MAPS       ?= e1m1 e1m2 e1m3 e1m4 e1m5 e1m6 e1m7 e1m8 start
MAP_ASSETS := $(if $(wildcard $(PAK)),$(foreach m,$(MAPS),data/maps/$(m)/assets.zip))
EXE  := $(BUILD)/qrender.exe

.PHONY: all build run viz qb45 pds evidence assets test clean help

all: build                      ## build the renderer (default)
build: $(EXE)
assets: $(ASSETS) $(MDL_ASSETS) $(GFX_ASSETS) $(CAM_ASSETS) $(MAP_ASSETS)   ## regenerate the preprocessed textures
maps: $(MAP_ASSETS)             ## the chainable maps' assets

$(foreach m,$(MAPS),data/$(m).bsp): data/%.bsp: $(PAK) tools/pakget.py
	@python3 tools/pakget.py $(PAK) maps/$*.bsp $@

data/maps/%/assets.zip: data/%.bsp data/base.dat tools/mkassets.py tools/mkportals.py
	@mkdir -p data/maps/$*
	@python3 tools/mkassets.py data/$*.bsp data/base.dat data/maps/$* $(or $(SKILL),0) $(PAK)
	@cp data/$*.bsp data/maps/$*/

$(ASSETS): data/$(MAP) data/base.dat tools/mkassets.py tools/mkportals.py
	@python3 tools/mkassets.py data/$(MAP) data/base.dat data/assets $(or $(SKILL),0) $(PAK)

# .geo stands in for the three files mkmdl.py writes, the way assets.zip
# stands in for the texture set.
data/assets/$(MDL).geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) $(MDL) data/assets stand,run,death,pain

# the knight: 108 vertices, so its sword attack fits the page too
data/assets/knight.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) knight data/assets stand,runb,death,pain,attackb

# the dog: 236 vertices, so 23 frames fill the page -- one to stand, the
# run, the death, one flinch; no attack set, it bites on the run
data/assets/dog.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) dog data/assets stand:1,run,death,pain:1

# the ogre: 169 vertices, 32 frames -- the grenade's shoot set, no saw frames
data/assets/ogre.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) ogre data/assets stand:1,run,death,pain:3,shoot

# the demon: 143 vertices, 38 frames -- the claws fit, the leap does not
data/assets/demon.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) demon data/assets stand:1,run,death,pain:3,attacka

# the zombie: 177 vertices, 30 frames -- no death set, it is gibbed; the
# fall (paine, 30 frames) does not fit, so it lies on paina's last
data/assets/zombie.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) zombie data/assets stand:1,run:8,death,paina:8,atta

# the wizard: 80 vertices, all 54 frames
data/assets/wizard.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) wizard data/assets hover,fly,death,pain,magatt

# 144 vertices, 37 frames fit: the lightning is the attack set, the smash
# lands from the run cycle
data/assets/shambler.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) shambler data/assets stand:1,run,death,pain,magic

# the view weapon: shot1..7, the fire animation
data/assets/v_shot.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) v_shot data/assets shot

data/assets/v_shot2.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) v_shot2 data/assets shot

data/assets/v_nail.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) v_nail data/assets shot

data/assets/v_rock.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) v_rock data/assets shot

data/assets/v_nail2.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) v_nail2 data/assets shot

data/assets/v_rock2.geo: $(PAK) tools/mkmdl.py
	@python3 tools/mkmdl.py $(PAK) v_rock2 data/assets shot

# sbar.raw stands in for sbnum.raw too
data/assets/sbar.raw: $(PAK) tools/mkgfx.py
	@python3 tools/mkgfx.py $(PAK) data/assets

# the sound effects: snd.raw stands in for sndtab.raw beside it
data/assets/snd.raw: $(PAK) tools/mksnd.py
	@python3 tools/mksnd.py $(PAK) data/assets

data/assets/campath.bin: data/$(MAP) tools/campath.py
	@python3 tools/campath.py data/$(MAP) data/assets

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
	$(JWASM) -c -Cp -Zg -omf $(if $(filter 1,$(DEBUGINFO)),-Zi,) -D__BASIC__=1 $(QGL_DEFS) -I$(CURDIR)/src/qgl -Fo$@ $<

$(BUILD)/stuff.ini: data/stuff.ini | $(BUILD)
	cp $< $@

$(BUILD)/base.dat: data/base.dat | $(BUILD)
	cp $< $@

# qgl_txt_load wants a loose file beside the exe, not a PACK member --
# see txt.asm's own note that this is mkfont.py's job, not INT 21h's.
$(BUILD)/FONT.FNT: data/base.dat tools/mkfont.py | $(BUILD)
	@python3 tools/mkfont.py data/base.dat font/4x6.fnt $@

# Copy the whole directory rather than naming extensions, which is how
# the .bld lumps silently failed to stage the first time this was
# written by hand.
$(BUILD)/.assets-stamp: $(ASSET_FILES) | $(BUILD)
	cp -R data/assets/* $(BUILD)/
	touch $@

$(BUILD)/.assets-stamp: $(MDL_ASSETS) $(CAM_ASSETS)

$(BUILD)/.maps-stamp: $(MAP_ASSETS) | $(BUILD)
	$(if $(MAP_ASSETS),mkdir -p $(BUILD)/MAPS && cp -R $(foreach m,$(MAPS),data/maps/$(m)) $(BUILD)/MAPS/,)
	touch $@

$(BUILD)/GOMAP.BAT: data/gomap.bat | $(BUILD)
	cp $< $@

$(EXE): $(BAS_OBJS) $(C_OBJS) $(ASM_OBJS) $(BUILD)/stuff.ini $(BUILD)/base.dat $(BUILD)/FONT.FNT $(BUILD)/.assets-stamp $(BUILD)/.maps-stamp $(BUILD)/GOMAP.BAT
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

clean:                          ## drop all build output
	rm -rf build

help:
	@grep -hE '^[a-z0-9]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t 14
