/* jonesforth RV32EC on the CH32V006F8U6 (62k flash, 8k SRAM)
 *
 * Linked at the 0x00000000 flash alias: the QingKe V2 resets to and executes
 * from there, and PC-relative `la` of RAM symbols breaks if the link base
 * differs from the execution base (fotrh lesson #2).
 *
 * The kernel plus the embedded boot script must fit in 24k; growing past
 * that must fail the link, not silently eat the BLOCK region above
 * (blocks: 0x08006000..0x0800F800, 38 x 1 KiB).
 */
MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 24k
    RAM (xrw)   : ORIGIN = 0x20000000, LENGTH = 8k
}

ENTRY(_start);

SECTIONS {
    .text : {
        . = ALIGN(4);
        *(.text)
        *(.rodata)
        . = ALIGN(4);
    } >FLASH

    /* the boot script is read byte-wise up to its 0xFF sentinel; keep it
       after everything else so nothing follows it in the binary */
    .bootf : {
        KEEP(*(.bootf))
    } >FLASH
}
