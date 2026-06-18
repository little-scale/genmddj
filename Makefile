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

$(FONT): tools/makefont.py tools/font8x8_basic.h | $(BUILD)
	python3 tools/makefont.py tools/font8x8_basic.h $(FONT)

$(NOTES): tools/maketables.py | $(BUILD)
	python3 tools/maketables.py $(NOTES)

$(Z80BIN): $(Z80SRC) | $(BUILD)
	wla-z80 -o $(BUILD)/driver.z80.o $(Z80SRC)
	printf '[objects]\n$(BUILD)/driver.z80.o\n' > $(BUILD)/driver.link
	wlalink -b $(BUILD)/driver.link $(Z80BIN)

$(RAW): $(SRCS) $(FONT) $(NOTES) $(Z80BIN) | $(BUILD)
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
