ASM   := vasmm68k_mot
BUILD := build
RAW   := $(BUILD)/genmddj.raw
ROM   := $(BUILD)/genmddj.bin
EMU   := mednafen

SRCS  := src/main.asm

all: $(ROM)

$(BUILD):
	mkdir -p $(BUILD)

ASMFLAGS := -Fbin -spaces -quiet -m68000
FONT     := $(BUILD)/font.bin
NOTES    := $(BUILD)/notes.bin
Z80SRC   := src/z80/driver.asm
Z80BIN   := $(BUILD)/driver.z80.bin
SAMPLES  := $(BUILD)/samples.bin

$(SAMPLES): tools/makesamples.py | $(BUILD)
	python3 tools/makesamples.py samples $(SAMPLES)

# FORCE (like the factory bank): so adding/changing/removing tools/font_custom.bin always re-bakes the font.
$(FONT): tools/makefont.py FORCE | $(BUILD)
	python3 tools/makefont.py $(FONT)

$(NOTES): tools/maketables.py | $(BUILD)
	python3 tools/maketables.py $(NOTES)

$(Z80BIN): $(Z80SRC) | $(BUILD)
	wla-z80 -o $(BUILD)/driver.z80.o $(Z80SRC)
	printf '[objects]\n$(BUILD)/driver.z80.o\n' > $(BUILD)/driver.link
	wlalink -b $(BUILD)/driver.link $(Z80BIN)

SPLASH := $(BUILD)/splash.i
GITVER := $(BUILD)/gitver.i
ALGOS  := $(BUILD)/algos.i
FACTORY := $(BUILD)/fm_factory.bin

$(SPLASH): tools/makesplash.py art/genmddj.png | $(BUILD)
	python3 tools/makesplash.py art/genmddj.png \
	    $(BUILD)/splash_tiles.bin $(BUILD)/splash_map.bin $(SPLASH) 32

$(ALGOS): tools/makealgos.py | $(BUILD)
	python3 tools/makealgos.py \
	    $(BUILD)/algo_tiles.bin $(BUILD)/algo_maps.bin $(ALGOS)

# FM factory bank: baked from instrument-patches/*.gmi (filename order; name from the filename).
# FORCE (not a wildcard prereq) because the .gmi filenames contain spaces, which Make can't list.
$(FACTORY): tools/makeinstruments.py FORCE | $(BUILD)
	python3 tools/makeinstruments.py instrument-patches $(FACTORY)

# build stamp: regenerated every build (FORCE) so hash/dirty flag stay current
$(GITVER): FORCE | $(BUILD)
	@hash=`git rev-parse --short=7 HEAD 2>/dev/null || echo 0000000`; \
	 dirty=`test -n "$$(git status --porcelain 2>/dev/null)" && echo + || echo`; \
	 printf 'git_hash_str:\n    dc.b "%s%s",0\n' "$$hash" "$$dirty" > $(GITVER)
FORCE:

$(RAW): $(SRCS) $(FONT) $(NOTES) $(Z80BIN) $(SAMPLES) $(SPLASH) $(ALGOS) $(GITVER) $(FACTORY) | $(BUILD)
	$(ASM) $(ASMFLAGS) -o $(RAW) src/main.asm

$(ROM): $(RAW) tools/fixheader.py
	python3 tools/fixheader.py $(RAW) $(ROM)

run: $(ROM)
	$(EMU) $(ROM)

# --- headless screenshot (no GUI / permissions needed) ---
EMUDIR    := tools/emu
EMUCORE   := $(EMUDIR)/genesis_plus_gx_libretro.dylib
RETROSHOT := $(EMUDIR)/retroshot
FRAMES    ?= 90

$(RETROSHOT): $(EMUDIR)/harness.c $(EMUDIR)/libretro.h
	clang -O2 -o $@ $(EMUDIR)/harness.c -I$(EMUDIR)

shot: $(ROM) $(RETROSHOT)
	$(RETROSHOT) $(EMUCORE) $(ROM) $(BUILD)/shot.ppm $(FRAMES)
	python3 -c "from PIL import Image; Image.open('$(BUILD)/shot.ppm').save('$(BUILD)/shot.png')"
	@echo "wrote $(BUILD)/shot.png"

clean:
	rm -rf $(BUILD)

.PHONY: all run shot clean
