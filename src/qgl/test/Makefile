# The qgl suite: one asm test per file, assembled and linked natively
# with jwasm+jwlink, each run in its own headless DOSBox.
#
#   make            run everything
#   make t01base    run one test
#
# No DOS toolchain, no BASIC, no UGLV.LIB: the tests link the qgl objects
# directly plus memstub for the allocator. That is what makes a failure
# here point at qgl rather than at the renderer around it.
TC     ?= $(HOME)/work/other/d32x/toolchains/native/bin
DOSBOX ?= $(HOME)/work/other/dosbox-x-debug/src/dosbox-x
ROOT   := $(abspath ../../..)
QGL    := $(abspath ..)
B      ?= $(ROOT)/build/qgl-test
JWASM  := $(TC)/jwasm -c -Cp -Zg -omf -I$(QGL) -I.
JWLINK := $(TC)/jwlink

TESTS  := t01base t02mem t03surf t04txt t05file

# The layer under test. Every test links all of it -- these are small and
# a per-test object list would drift from reality the first time a module
# grew a dependency.
QGLSRC := $(QGL)/vga.asm $(QGL)/gem.asm $(QGL)/sf.asm $(QGL)/mem.asm $(QGL)/txt.asm $(QGL)/file.asm
QGLOBJ  = $(patsubst $(QGL)/%.asm,$(B)/%/qgl_%.obj,$(QGLSRC))

all: $(TESTS:%=$(B)/%/pass)
	@echo "qgl suite: $(words $(TESTS)) tests PASS"

$(TESTS): %: $(B)/%/pass

$(B)/%/pass: $(B)/%/t.exe run1.sh
	@sh run1.sh $(DOSBOX) $(@D)

$(B)/%/t.exe: %.asm tfw.asm tfw.inc $(QGLSRC) $(QGL)/qgl.inc
	@mkdir -p $(@D)
	@$(JWASM) -Fo$(@D)/test.obj $< > /dev/null
	@$(JWASM) -Fo$(@D)/tfw.obj tfw.asm > /dev/null
	@$(JWASM) -Fo$(@D)/vga.obj $(QGL)/vga.asm > /dev/null
	@$(JWASM) -Fo$(@D)/gem.obj $(QGL)/gem.asm > /dev/null
	@$(JWASM) -Fo$(@D)/sf.obj  $(QGL)/sf.asm  > /dev/null
	@$(JWASM) -Fo$(@D)/mem.obj $(QGL)/mem.asm > /dev/null
	@$(JWASM) -Fo$(@D)/txt.obj $(QGL)/txt.asm > /dev/null
	@$(JWASM) -Fo$(@D)/file.obj $(QGL)/file.asm > /dev/null
	@$(JWLINK) option quiet format dos name $@ \
	    file $(@D)/test.obj,$(@D)/tfw.obj,$(@D)/vga.obj,$(@D)/gem.obj,$(@D)/sf.obj,$(@D)/mem.obj,$(@D)/txt.obj,$(@D)/file.obj

clean:
	rm -rf $(B)

.SECONDARY:
.PHONY: all clean $(TESTS)
