# Build the DRAM payload for the FEL eMMC tool.
# The SPL stub is built from a U-Boot tree, see README.md.

CROSS_COMPILE ?= aarch64-linux-gnu-
CC      := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy

CFLAGS := -O2 -ffreestanding -fno-builtin -fno-stack-protector -fno-common \
	  -march=armv8-a -mgeneral-regs-only -Wall -Wextra

all: payload.bin

payload.o: payload.c
	$(CC) $(CFLAGS) -c -o $@ $<

payload.elf: payload.o link.ld
	$(CC) -nostdlib -T link.ld -Wl,--build-id=none -o $@ payload.o

payload.bin: payload.elf
	$(OBJCOPY) -O binary $< $@
	@printf 'payload: %s bytes\n' "$$(wc -c < $@)"

clean:
	rm -f payload.o payload.elf payload.bin

.PHONY: all clean
