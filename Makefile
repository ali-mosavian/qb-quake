##
## qb-qrender -- Quake BSP renderer in BASIC, built for real-mode DOS.
##
## The compiler and linker are DOS programs, so every target here shells out
## to tools/dosbox.sh, which stages src/ and data/ into build/<target>/ and
## drives DOSBox-X. A full build takes minutes under emulation, so the exe is
## a real file target with real prerequisites -- `make` is a no-op when
## nothing changed.
##

MGL        ?= $(HOME)/work/badlogic/mgl
TOOLCHAINS ?= $(HOME)/work/other/d32x/toolchains
DOSBOX_BIN ?=
MAP        ?= dm3ish.bsp
TIMEOUT    ?= 600

SRCS := $(wildcard src/*.bas)
HDRS := $(wildcard src/*.bi)
DATA := data/stuff.ini data/base.dat
## Preprocessed textures. The renderer blits these instead of resampling and
## colour-matching the miptex lump at every launch; the raw atlas stands in
## for the whole set as far as make is concerned.
ASSETS := data/assets/texr.bmp
HARNESS := tools/dosbox.sh dosbox/template.conf
EXE  := build/vbd/qrender.exe

export MGL TOOLCHAINS DOSBOX_BIN TIMEOUT

.PHONY: all build run viz qb45 pds evidence assets clean help

all: build                      ## build the renderer (default)
build: $(EXE)
assets: $(ASSETS)         ## regenerate the preprocessed textures

$(ASSETS): data/$(MAP) data/base.dat tools/mkassets.py
	@python3 tools/mkassets.py data/$(MAP) data/base.dat data/assets

$(EXE): $(SRCS) $(HDRS) $(DATA) $(ASSETS) $(HARNESS)
	@python3 tools/qblint.py
	@tools/dosbox.sh build
	@# the exe's mtime comes from the DOS guest's clock, which need not agree
	@# with the host's -- stamp it so make's bookkeeping is sound
	@test -f $@ && touch $@

run: $(EXE)                     ## headless run; 's' screenshots to build/vbd/
	@tools/dosbox.sh run $(MAP)

viz: $(EXE)                     ## windowed run, to watch it live
	@echo "launch: dosbox-x -conf $$(tools/dosbox.sh viz $(MAP))"

## The two failing toolchains are kept as reproducible evidence for the
## README's claim that VBDOS is required rather than merely preferred.
qb45:                           ## reproduce the QB 4.5 failure
	@tools/dosbox.sh build qb45
pds:                            ## reproduce the PDS 7.1 failure
	@tools/dosbox.sh build pds
evidence: qb45 pds

clean:                          ## drop all build output
	rm -rf build

help:
	@grep -hE '^[a-z0-9]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t 14
