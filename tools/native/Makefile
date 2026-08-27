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

# Overridable so concurrent builds do not share one output tree. Two
# processes running this Makefile against the same BUILD each do
# `rm -f X.LIB && jwlib X.LIB +objs`, so the loser's library comes out
# missing whatever the winner was mid-write on -- which presents as an
# unresolved external in a DIFFERENT module each time, not as a build
# error. Set BUILD per worktree/session to avoid it.
BUILD    ?= $(CURDIR)/build/native-mgl
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

# B15/B16/B32 are NOT built here: qrender creates only 8-bit DCs
# (env.c_fmt is UGL.8BIT everywhere -- confirmed by grep), so their
# fillers are pure dead weight for this project. uglmain.asm still
# references b15_Init/b15_End/b16_Init/b16_End/b32_Init/b32_End
# unconditionally (a static CFMT table, ul$cfmtTB, one row per format,
# built at assemble time and walked in full by uglInit/_end) -- STUB
# supplies minimal stand-ins for exactly those six symbols, from THIS
# project's own tree (tools/native/stubs/fmtstub.asm), not mgl's. mgl
# itself is untouched; swap B15/B16/B32 back into LIBS and drop STUB to
# revert.
# 2DFX (tfxmain, tfxblt, ...) is also NOT built here: nothing outside
# src/2dfx/ references any tfx* symbol anywhere in mgl (checked: only
# ugl.inc defines FMT_1BIT/FMT_4BIT, the two format constants 2DFX uses,
# and neither is read by uglInit's CLR_FORMATS loop -- 2DFX is not wired
# into any unconditional startup table the way CFMT was), and qrender's
# own source never calls anything tfx*. No stub needed: if that reasoning
# is wrong the linker will say so by name, the same way it did for
# b15_8/b16_8/b32_8.
LIBS := DOS EMS XMS DCT MODS MISC B8 UGL UGLU \
        MUSIC XSND SNDDRV STUB

DIR_DOS   := dos
MODS_DOS  := dosfile dosmem dosbfile

DIR_EMS   := ems
MODS_EMS  := emsalloc emsavail emsblock emsfill emsfree emsheap emsmap emssave emsmapex emsmapq

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
             8plxf 8plxg 8plxt 8plxtp 8plxtg 8plxtpg 8plxtz 8conv_m
# 8plxtz holds the depth-aware fillers. 8plxt.asm and 8plxtp.asm REFERENCE
# them (UL$HLINET8_ZT, UL$ZACC, HLINET_FIXUP_Z), so leaving it out of the
# list produces a library that links only by luck -- whatever stale
# 8plxtz.obj happens to be in the build tree. A genuinely clean build
# fails with unresolved externals in a module the list does name.

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
             uglpltpg uglrtscl uglpal ugllut uglpalfx uglview uglsurf uglshade uglwin uglz uglarr

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

# ── header dependencies ───────────────────────────────────────────────
# Neither bcc (DOS-hosted, driven through bcc.sh) nor jwasm emits any
# dependency information, so without this every object depends only on its
# own source file. That is not a cosmetic gap: editing a struct in a shared
# header rebuilds just the .c files that changed and silently re-archives
# every other object still compiled against the previous layout. Inserting
# three uint32 counters into the middle of XS_CTX did exactly that -- the
# rebuilt sndmixer/sndint/sndmain/sndctrl saw the new layout while
# sndnew.obj and sndplay.obj kept addressing every field past voices_lock
# 12 bytes off, and modNew wedged with no error from bcc, jwlib or LINK.
#
# Tracked coarsely -- every object depends on every header in the tree.
# Over-broad by design: a full rebuild costs minutes, a stale object costs
# a day of bisecting an emulator.
HDRS := $(shell find $(MGL)/inc $(SRC) \( -name '*.h' -o -name '*.inc' \) 2>/dev/null)

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

$(BUILD)/$(1)/%.obj: $(SRC)/$(DIR_$(1))/%.asm $(HDRS) | $(BUILD)/$(1)
	@# jwasm embeds whatever filename string it's given into the object's
	@# THEADR record verbatim. Passing the full absolute path makes for a
	@# ~50-byte THEADR that jwlib's OMF reader rejects outright as
	@# "invalid object file" -- cd in first and pass the bare filename,
	@# matching every DOS-hosted build (dmake, mkswp.bat) doing the same.
	cd $(SRC)/$(DIR_$(1)) && $(JWASM) $(JWASMFLAGS) -Fo$$@ $$(notdir $$<)

$(BUILD)/$(1)/%.obj: $(SRC)/$(DIR_$(1))/%.c $(HDRS) | $(BUILD)/$(1)
	MGL=$(MGL) $(BCC) src/$(DIR_$(1))/$$(notdir $$<) $$@

$(BUILD)/$(1).LIB: $$(addprefix $(BUILD)/$(1)/,$$(addsuffix .obj,$$(MODS_$(1)) $$(CMODS_$(1))))
	rm -f $$@
	$(JWLIB) $$@ $$(addprefix +,$$^)
endef

# STUB is not a real mgl sub-library -- it has no DIR_STUB/MODS_STUB and
# no source under mgl's own tree -- so it is excluded from the generic
# per-library rule generator and given its own small rule instead,
# pointing at THIS project's tools/native/stubs/ directory.
$(foreach lib,$(filter-out STUB,$(LIBS)),$(eval $(call BUILD_LIB,$(lib))))

STUBSRC := $(CURDIR)/tools/native/stubs

$(BUILD)/STUB:
	mkdir -p $@

$(BUILD)/STUB/fmtstub.obj: $(STUBSRC)/fmtstub.asm | $(BUILD)/STUB
	cd $(STUBSRC) && $(JWASM) $(JWASMFLAGS) -Fo$@ fmtstub.asm

$(BUILD)/STUB.LIB: $(BUILD)/STUB/fmtstub.obj
	rm -f $@
	$(JWLIB) $@ +$(BUILD)/STUB/fmtstub.obj

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

# ── tests ───────────────────────────────────────────────────────────────
# `make check` builds the libs, then runs every mgl test against THIS
# build rather than a prebuilt lib -- same rule the rest of this file
# follows, and for the same reason: a shipped lib predates whatever is
# being tested, so a green run against one proves nothing.
#
# Not wired into `all`. Each test boots DOSBox, so the suite costs
# minutes; a build that ran it by default would stop being a build.
.PHONY: check
check: $(UGLV)
	UGLLIB=$(UGLV) $(MGL)/src/test/runall.sh
