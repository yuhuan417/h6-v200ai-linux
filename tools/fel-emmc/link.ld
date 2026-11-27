/* The payload is loaded at PAYLOAD_ADDR and called through the header:
 *   +0  magic 'PLY1'
 *   +4  entry offset from PAYLOAD_ADDR
 * The linker fills both in, so code changes never desync the stub.
 */
ENTRY(payload)
SECTIONS
{
	. = 0x42000000;
	.payload_hdr : {
		LONG(0x504C5931);
		LONG(payload - 0x42000000);
	}
	. = ALIGN(16);
	.text : { KEEP(*(.text.entry)) *(.text*) }
	.rodata : { *(.rodata*) }
	.data : { *(.data*) }
	.bss : { *(.bss*) *(COMMON) }
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
