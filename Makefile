# jonesforth for RV32EC / CH32V006

CROSS   ?= riscv64-unknown-elf-
AS      := $(CROSS)as
LD      := $(CROSS)ld
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump

ARCH    := rv32ec_zicsr_zmmul
DEVICE  ?= /dev/ttyACM0

all: jonesforth.bin
build: jonesforth.bin

jonesforth.o: jonesforth.S mcu.s board.s boot.f
	$(AS) -g -march=$(ARCH) -mno-relax -I. -o $@ jonesforth.S

jonesforth.elf: jonesforth.o linker.ld
	$(LD) -m elf32lriscv -T linker.ld -o $@ $<

jonesforth.bin: jonesforth.elf
	$(OBJCOPY) -O binary $< $@

dump: jonesforth.elf
	$(OBJDUMP) -D $< > jonesforth.dump

test: jonesforth.bin
	python3 tools/test.py

flash: jonesforth.bin
	minichlink -w jonesforth.bin flash -b

term:
	picocom -b 115200 --omap crcrlf --imap lfcrlf $(DEVICE)

clean:
	rm -f jonesforth.o jonesforth.elf jonesforth.bin jonesforth.dump

.PHONY: all build dump test flash term clean
