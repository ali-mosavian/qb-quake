##
## cport -- the standalone C rewrite of qrender. No BASIC runtime: this
## links uGL built with __CMP__=BC and Borland C's own medium-model
## startup/runtime (tc201's C0M.OBJ/CM.LIB/MATHM.LIB), not VBDCL10E.LIB.
##
## Each compile is its own DOSBox-X session (cport/tools/bcc.sh), same
## reasoning as the main project's top-level Makefile: `make -jN`
## genuinely parallelises only if nothing shares a session. Link stays
## single -- it needs every object at once.
##
## NATIVE_UGL must already exist, built with __CMP__=BC:
##   make -f ../tools/native/Makefile BUILD=$PWD/../build/native-mgl-bc \
##        JWASMFLAGS="-c -Cp -Zg -D__CMP__=BC -I$MGL/src/inc -omf"
##

TOOLCHAINS ?= $(HOME)/work/other/d32x/toolchains
DOSBOX_BIN ?=
BUILD      ?= $(CURDIR)/../build/cport
NATIVE_UGL ?= $(CURDIR)/../build/native-mgl-bc/UGLV.LIB
JWASM      ?= $(TOOLCHAINS)/native/bin/jwasm

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

MODS := $(C_MODS) $(ASM_MODS)
OBJS := $(addprefix $(BUILD)/,$(addsuffix .obj,$(MODS)))
EXE  := $(BUILD)/QCPORT.EXE

.PHONY: all build run clean help

all: build                      ## build the standalone renderer (default)
build: $(EXE)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.obj: src/%.c | $(BUILD)
	$(BCC) $< $@

$(BUILD)/%.obj: src/%.asm | $(BUILD)
	$(JWASM) -c -Cp -Zg -omf -Fo$@ $<

$(EXE): $(OBJS)
	CPORT_UGL="$(NATIVE_UGL)" $(LINK) $(BUILD) "$(MODS)"

run: $(EXE)                     ## headless run; cport.txt/cstep.txt land in $(BUILD)
	@tools/run.sh $(BUILD)

clean:                          ## drop all build output
	rm -rf $(BUILD)

help:
	@grep -hE '^[a-z0-9]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t 14
