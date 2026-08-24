# Native macOS build of µGL (mgl) -- no DOSBox, no dmake.
#
# Uses the jwasm/jwlink/jwlib built per README.md, in place of
# ml.exe/link16/lib16 under DOSBox-X. Produces UGLV.LIB, matching the DOS
# build's release/vbd/uglv.lib -- with one gap, see "Known gap" below.
#
#   make -f tools/native/Makefile              build UGLV.LIB
#   make -f tools/native/Makefile clean
#   make -f tools/native/Makefile MGL=/path/to/mgl
#
# mgl itself is a separate, uncommitted source tree (see AGENTS.md) --
# this Makefile only reads from it, never writes into it.

MGL      ?= $(HOME)/work/badlogic/mgl
SRC      := $(MGL)/src
INC      := $(SRC)/inc

NATIVE   := $(HOME)/work/other/d32x/toolchains/native/bin
JWASM    := $(NATIVE)/jwasm
JWLIB    := $(NATIVE)/jwlib
# music/, xsnd/ and xsnd/snddrv/ are C, so jwasm can't build them; bcc 3.1
# under DOSBox-X can, one process per file so -j still parallelises.
BCC      := $(CURDIR)/tools/bcc.sh

BUILD    := $(CURDIR)/build/native-mgl
UGLV     := $(BUILD)/UGLV.LIB

# -Zg (Masm-compatible code generation) is required, not cosmetic: without
# it jwasm binds an `externdef X:far` issued *inside* a segment to that
# segment, so OFFSET/SEG of X get a fixup frame of the *referencing*
# segment instead of FRAME_TARG. MS LINK then reports "L2002: fixup
# overflow" for every SET_FMT in cfmt/*/​*main.asm. MASM 6.11 emits
# FRAME_TARG here; jwasm only matches it under -Zg.
JWASMFLAGS := -c -Cp -Zg -D__CMP__=VBD -I$(INC) -omf

# ── per sub-library: source directory + ASM module list ─────────────────
# Transcribed from each src/**/​*.mk's ASMLIST (see tools/native/README.md
# for how). Order matches mgl's own src/makefile.mk SRC variable.

LIBS := DOS EMS XMS DCT MODS MISC B8 B15 B16 B32 UGL UGLU 2DFX \
        MUSIC XSND SNDDRV

DIR_DOS   := dos
MODS_DOS  := dosfile dosmem dosbfile

DIR_EMS   := ems
MODS_EMS  := emsalloc emsavail emsblock emsfill emsfree emsheap emsmap emssave

DIR_XMS   := xms
MODS_XMS  := xmsalloc xmsavail xmsblock xmsfill xmsfree xmsheap xmsmap

DIR_MODS  := mods
MODS_MODS := mdfont mdkbd mdmouse mdtimer mdvbe mdarch mdu3d

DIR_MISC  := misc
MODS_MISC := mscmisc msccpu msclog mscopmov mscopsto mscexitq mscshfa \
             mscshga mscshta mscshtp mscshtag mscshtpg msemsemu

DIR_DCT   := dct
MODS_DCT  := dctbnk dctems dctmem dctxms

DIR_B8    := cfmt/b8
MODS_B8   := 8main 8conv 8pixel 8line 8vline 8putm 8putb 8puts 8hflip \
             8plxf 8plxg 8plxt 8plxtp 8plxtg 8plxtpg 8conv_m

DIR_B15   := cfmt/b15
MODS_B15  := 15main 15conv 15putm 15hflip 15plxg 15plxtg 15conv_m 15puts

DIR_B16   := cfmt/b16
MODS_B16  := 16main 16conv 16pixel 16line 16vline 16putm 16hflip 16plxf \
             16plxg 16plxt 16plxtg 16conv_m 16puts

DIR_B32   := cfmt/b32
MODS_B32  := 32main 32conv 32pixel 32line 32vline 32putm 32hflip 32plxf \
             32plxg 32plxt 32plxtg 32conv_m 32puts

DIR_UGL   := ugl
MODS_UGL  := uglbez uglbmp uglelip uglelipf uglclear uglcolor uglconv \
             ugldc ugldel uglget uglhline uglline uglmain uglmode uglnew \
             uglpage uglpixel uglpoly uglpolyf uglput uglputm uglputb \
             uglputs uglblit uglblits uglblitr uglrect uglrectf uglrow \
             uglsel uglvline uglplxf uglplxg uglplxt uglplxtp uglplxtg \
             uglpltpg uglrtscl uglpal ugllut uglpalfx uglview uglsurf

DIR_UGLU  := uglu
MODS_UGLU := glubez glubez3d glucpuft gludcsav

# ── the C sub-libraries (bcc, not jwasm) ────────────────────────────────
# CMODS_* are .c; MODS_* stay .asm. Lists come from each dir's own .mk
# (CPPLIST and ASMLIST respectively).

DIR_MUSIC  := music
MODS_MUSIC := modamain
CMODS_MUSIC := modcmn modctrl modload modmain modmem modplay modtbl

DIR_XSND   := xsnd
MODS_XSND  := sndamain
CMODS_XSND := sndconv sndctrl sndint sndmain sndmixer sndnew sndplay

DIR_SNDDRV   := xsnd/snddrv
MODS_SNDDRV  :=
CMODS_SNDDRV := sbdrv

DIR_2DFX  := 2dfx
# tfxUnpk/tfxPack/tfxSolid/tfxLut: mixed case on disk, unlike every other
# module in the tree -- 2DFX.mk's own ASMLIST spells them lowercase, which
# only worked because DOS's filesystem is case-insensitive.
MODS_2DFX := tfxmain tfxblt tfxbltsc tfxUnpk tfxPack tfxSolid tfxLut \
             tfxblend tfxinvt tfxscale tfxmono tfxcol2

# ── rules ─────────────────────────────────────────────────────────────

.PHONY: all clean
all: $(UGLV)

$(BUILD):
	mkdir -p $(BUILD)

# one obj-dir + assemble rule + archive rule per sub-library, generated
# from the LIBS list above (GNU make 3.81: eval + call, no newer features)
define BUILD_LIB
$(BUILD)/$(1):
	mkdir -p $$@

$(BUILD)/$(1)/%.obj: $(SRC)/$(DIR_$(1))/%.asm | $(BUILD)/$(1)
	@# jwasm embeds whatever filename string it's given into the object's
	@# THEADR record verbatim. Passing the full absolute path makes for a
	@# ~50-byte THEADR that jwlib's OMF reader rejects outright as
	@# "invalid object file" -- cd in first and pass the bare filename,
	@# matching every DOS-hosted build (dmake, mkswp.bat) doing the same.
	cd $(SRC)/$(DIR_$(1)) && $(JWASM) $(JWASMFLAGS) -Fo$$@ $$(notdir $$<)

$(BUILD)/$(1)/%.obj: $(SRC)/$(DIR_$(1))/%.c | $(BUILD)/$(1)
	MGL=$(MGL) $(BCC) src/$(DIR_$(1))/$$(notdir $$<) $$@

$(BUILD)/$(1).LIB: $$(addprefix $(BUILD)/$(1)/,$$(addsuffix .obj,$$(MODS_$(1)) $$(CMODS_$(1))))
	rm -f $$@
	$(JWLIB) $$@ $$(addprefix +,$$^)
endef

$(foreach lib,$(LIBS),$(eval $(call BUILD_LIB,$(lib))))

$(UGLV): $(foreach lib,$(LIBS),$(BUILD)/$(lib).LIB)
	rm -f $@
	$(JWLIB) $@ $(foreach lib,$(LIBS),+$(BUILD)/$(lib).LIB)
	@echo "built $@"

clean:
	rm -rf $(BUILD)

# ── known gaps ────────────────────────────────────────────────────────
#
# MUSIC, XSND, SNDDRV (per each's own .mk) are C, built with Borland C++
# 3.1 -- no native macOS cross-compiler targets 16-bit real-mode DOS with
# Borland's ABI. Not built here at all, matching tools/mglbuild.sh's own
# scope.
#
# DCT (EMS/XMS/VBE bank-switched memory access -- dctbnk, dctems, dctmem,
# dctxms) is excluded because jwasm miscompiles all four. Each opens the
# `ugl_text` segment via the UGL_CODE macro, switches away with a plain
# `.code`, then re-enters `ugl_text` a second (dctems: third) time later
# in the file -- every other module in the tree that uses UGL_CODE does
# so exactly once. On re-entry jwasm silently drops the LEDATA record
# header in front of the resumed segment's code bytes: the raw
# instruction stream (starting with a stray 0x2e CS-override prefix byte)
# gets written straight into the record stream, where it's read back as
# a bogus record type and desyncs everything after it. jwasm itself
# reports "0 errors" -- the object file is corrupt but the assembler
# never notices. Confirmed by manually walking each built .obj's OMF
# record stream: every file using UGL_CODE once parses cleanly: end of
# scan lands exactly on the file's last byte; the four DCT files desync
# a few hundred bytes in. Not chased further: bank-switched EMS/XMS/VBE
# access is irrelevant to a program (qrender.exe) that only ever uses
# mode 13h's linear framebuffer, so there was nothing to spend more time
# validating a fix against.
#
# UGLV.LIB above covers the same module set mglbuild.sh's --all does
# minus DCT -- not the full 16 sub-libraries the DOS dmake build produces.
