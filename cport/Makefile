##
## cport -- the standalone C rewrite of qrender. No BASIC runtime and no
## mgl: this links qgl's own objects plus Borland C's medium-model
## startup/runtime (tc201's C0M.OBJ/CM.LIB/MATHM.LIB), not VBDCL10E.LIB.
##
## qgl assembles natively with jwasm and WITHOUT __BASIC__ -- that define
## lets qgl call B$$SETM to hand memory back to BASIC's far heap, which
## is exactly the runtime this build does not have. qgl's own test suite
## has always linked this way, so free-standing is a configuration the
## layer already supports rather than one being invented here.
##
## Each compile is its own DOSBox-X session (cport/tools/bcc.sh), same
## reasoning as the main project's top-level Makefile: `make -jN`
## genuinely parallelises only if nothing shares a session. Link stays
## single -- it needs every object at once.
##

TOOLCHAINS ?= $(HOME)/work/other/d32x/toolchains
DOSBOX_BIN ?=
BUILD      ?= $(CURDIR)/../build/cport
JWASM      ?= $(TOOLCHAINS)/native/bin/jwasm
QGL        := $(CURDIR)/../src/qgl

# file.asm FIRST: a VFS driver registers by placing a row in a segment
# file.asm brackets, and TLINK lays the class out in the order it meets
# the modules. Same order src/qgl/test/Makefile uses.
QGL_SRC := $(QGL)/file.asm $(QGL)/vga.asm \
           $(QGL)/sf.asm $(QGL)/mem.asm $(QGL)/gem.asm \
           $(QGL)/qglnew.asm $(QGL)/qglview.asm $(QGL)/qgldc.asm \
           $(QGL)/qglrow.asm $(QGL)/dct/dctmem.asm $(QGL)/dct/dctems.asm \
           $(QGL)/txt.asm $(QGL)/dr.asm \
           $(QGL)/z.asm $(QGL)/clip.asm $(QGL)/rs.asm $(QGL)/sb.asm \
           $(QGL)/zip.asm $(QGL)/ar.asm $(QGL)/dsp.asm \
           $(QGL)/log.asm $(QGL)/tmr.asm $(QGL)/kbd.asm $(QGL)/mouse.asm \
           $(QGL)/m4.asm $(QGL)/cpi4.asm \
           $(QGL)/b8/b8fill.asm $(QGL)/b8/b8span.asm
QGL_MODS := $(basename $(notdir $(QGL_SRC)))
QGL_INC  := $(wildcard $(QGL)/*.inc)

export TOOLCHAINS DOSBOX_BIN

BCC  := $(CURDIR)/tools/bcc.sh
LINK := $(CURDIR)/tools/link.sh

C_SRC  := $(wildcard src/*.c)
C_MODS := $(basename $(notdir $(C_SRC)))

# Standalone .asm modules (r_ptproj.asm: r_ptproj/r_rclip) -- assembled
# natively with jwasm, same as the main project's top-level Makefile,
# not through a DOSBox session: no BASIC-side glue to reproduce, so
# there's nothing here that needs the emulator.
ASM_SRC  := $(wildcard src/*.asm)
ASM_MODS := $(basename $(notdir $(ASM_SRC)))

MODS := $(C_MODS) $(ASM_MODS) $(QGL_MODS)
OBJS := $(addprefix $(BUILD)/,$(addsuffix .obj,$(MODS)))
EXE  := $(BUILD)/QCPORT.EXE

.PHONY: all build run clean help

# assets.zip carries the lumps; TEXR/TEXS.RAW and pal.raw are loose
# because qgl maps the atlases into EMS a page at a time, which a
# deflated member cannot serve, and because qglVgaPalette wants the
# 8-bit palette rather than what the DAC would give back.
DATA_SRC := $(CURDIR)/../data/assets
DATA     := assets.zip TEXR.RAW TEXS.RAW pal.raw
DATA_OUT := $(addprefix $(BUILD)/,$(DATA))

all: build                      ## build the standalone renderer (default)
build: $(EXE) $(DATA_OUT)

# Named one by one, not a `$(BUILD)/%:` pattern -- that pattern also
# matches $(BUILD)/<anything>.obj and would compete with the compile
# rules for every object.
$(foreach f,$(DATA),$(eval $(BUILD)/$(f): $(DATA_SRC)/$(f) | $(BUILD); cp $$< $$@))

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.obj: src/%.c | $(BUILD)
	$(BCC) $< $@

$(BUILD)/%.obj: src/%.asm | $(BUILD)
	$(JWASM) -c -Cp -Zg -omf -Fo$@ $<

# No __BASIC__ here, deliberately -- see the header. On every .inc, the
# same reason the main project's rule takes them: qgl.inc carries the
# surface kinds and the struct layouts, so an edit there changes what
# these objects mean while leaving every .asm file untouched.
$(BUILD)/%.obj: $(QGL)/%.asm $(QGL_INC) | $(BUILD)
	$(JWASM) -c -Cp -Zg -omf -I$(QGL) -Fo$@ $<

$(BUILD)/%.obj: $(QGL)/b8/%.asm $(QGL_INC) | $(BUILD)
	$(JWASM) -c -Cp -Zg -omf -I$(QGL) -Fo$@ $<

$(BUILD)/%.obj: $(QGL)/dct/%.asm $(QGL_INC) | $(BUILD)
	$(JWASM) -c -Cp -Zg -omf -I$(QGL) -Fo$@ $<

# The header is generated, and a stale one miscompiles rather than
# failing: C will not catch a drifted declare the way BC does.
.PHONY: qglh
qglh:
	@python3 $(CURDIR)/../tools/mkqglh.py $(QGL) src/qgl.h --check \
	  || { python3 $(CURDIR)/../tools/mkqglh.py $(QGL) src/qgl.h; \
	       echo "qgl.h was stale and has been regenerated -- rebuild" >&2; \
	       exit 1; }

$(OBJS): | qglh

$(EXE): $(OBJS)
	$(LINK) $(BUILD) "$(MODS)"

run: $(EXE)                     ## headless run; cport.txt/cstep.txt land in $(BUILD)
	@tools/run.sh $(BUILD)

clean:                          ## drop all build output
	rm -rf $(BUILD)

help:
	@grep -hE '^[a-z0-9]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t 14
