# Build the Commander X16 port of Marble Madness from the sources here.
#
#   make                                  assemble and link MARBLE.PRG
#   make X16_DEFS="-D SPEED_EXTRA=0"      pass extra assembler options
#   make clean                            remove obj/ and MARBLE.PRG
#
# Needs ca65/ld65 (cc65) on PATH. MARBLE.PRG loads MMDATA.BIN at run time,
# so keep the two files together. Run "make clean" after changing X16_DEFS.

CA65     ?= ca65
LD65     ?= ld65
X16_DEFS ?=
ASFLAGS  := --cpu 65C02 -U $(X16_DEFS)

OBJDIR   := obj
PRG      := MARBLE.PRG
BANKS    := $(foreach b,0 1 2 3,$(OBJDIR)/bank$(b).o)
OBJS     := $(OBJDIR)/runtime.o $(BANKS) $(OBJDIR)/stubs.o
COMMON   := x16port.inc zeropage.inc

.PHONY: all clean

all: $(PRG)

$(PRG): $(OBJS) x16.cfg
	$(LD65) -C x16.cfg -m $(OBJDIR)/marble.map -Ln $(OBJDIR)/marble.lbl -o $@ $(OBJS)
	@echo "built $@ ($$(wc -c < $@) bytes); data file MMDATA.BIN"

$(OBJDIR)/bank%.o: bank%.s $(COMMON) | $(OBJDIR)
	$(CA65) $(ASFLAGS) -o $@ $<

$(OBJDIR)/stubs.o: stubs.s $(COMMON) | $(OBJDIR)
	$(CA65) $(ASFLAGS) -o $@ $<

$(OBJDIR)/runtime.o: runtime.s tables.inc debug_input.inc $(COMMON) | $(OBJDIR)
	$(CA65) $(ASFLAGS) -g -o $@ $<

$(OBJDIR):
	mkdir -p $@

clean:
	rm -rf $(OBJDIR) $(PRG)
