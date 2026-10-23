# jonesforth.S for RV32EC (WCH CH32V006, QingKe V2C) ------------------------
#
# A port of Richard W.M. Jones' jonesforth (public domain) from IA-32/Linux
# to bare-metal RISC-V.  The word set, dictionary layout, threading model
# (indirect), boolean convention (1/0, jonesforth's deliberate quirk) and
# even the word order below follow jonesforth.S; what differs is forced by
# the hardware:
#
#   - No OS: KEY/EMIT talk to USART1, the "data segment" is the 8 KiB SRAM,
#     and instead of SYSCALLn there are two flash primitives (FERASE, FPPROG)
#     on which classic BLOCK storage is built in Forth.
#   - RV32E: 16 registers.  Register plan (fixed, no remap archaeology):
#       sp = DSP   data stack pointer (full-descending)
#       s0 = RSP   return stack pointer (also holds spilled ra in helpers)
#       s1 = IP    Forth instruction pointer (%esi in the original)
#       a0 = W     working register; holds the codeword address for DOCOL
#       t0-t2,a1,a2,ra = helper-clobbered scratch
#       a3-a5,gp,tp    = extra scratch for primitive bodies (per-routine
#                        clobbers are documented where it matters)
#   - Zmmul subset: `mul` exists (used by NUMBER and * ), divide does not,
#     so /MOD is a 32-step restoring division with x86-idiv sign semantics
#     (quotient truncates toward zero, remainder takes the dividend's sign)
#     to stay behaviour-compatible with the original's idiv.
#   - QingKe V2 traps on misaligned word/halfword access: every lw/sw here
#     touches stacks, cells or word-aligned buffers; strings use byte ops;
#     LITSTRING re-aligns IP exactly like the original's addl $3/andl $~3.
#
# Silicon lessons inherited from the fotrh port (github.com/iksipsilon/fotrh):
# link at the 0x0 flash alias, RSP live before the first helper call, full
# CFGR0 write, 1 flash wait state at 24 MHz, 1 KiB-aligned trap beacon.
#
# Input model: jonesforth reads stdin; here _KEY serves three sources in
# order: the boot script in flash (.bootf section, terminated by 0xFF /
# erased flash; skipped by holding any key during reset), then line-buffered
# UART input with echo, backspace/DEL editing and an " ok" prompt when a
# fresh line is read in interpret state.
#
# This file is assembled standalone by GNU as (no C preprocessor):
#   as -march=rv32ec_zicsr_zmmul -I. jonesforth.S

# _start must be the very first bytes of flash: the QingKe resets to 0x0.
    .text
    .globl _start
_start:
    j boot

# Board (RAM_SIZE) and MCU (UART/GPIO/FPEC registers, uart_init, gpio_init)
# layers are reused from the fotrh CH32V006 port.  Included after _start so
# their code does not land on the reset vector.
    .include "board.s"
    .include "mcu.s"

# Memory map -----------------------------------------------------------------
#
#   0x20002000  RAM_END
#   0x20001FF0  DSP_TOP     (16-byte red zone above: a modest stack underflow
#                            stays inside RAM and is caught by INTERPRET's
#                            guard instead of trapping at the RAM boundary)
#   0x20001EF0  RSP_TOP     (data stack: 256 B)
#   0x20001DF0  TIB_END     (return stack: 256 B)
#   0x20001D70  TIB         (terminal input buffer: 128 B)
#   0x20001D40  WORD_BUFFER (WORD's static buffer: 32 B used, 48 reserved)
#   0x20001D00  variables   (16 cells)
#   0x20001900  BLK_BUFFER  (1 KiB block buffer, for BLOCK in Forth)
#   0x20000000  RAM_BASE    = HERE at boot; the dictionary grows up (6.25 KiB)
#
# Flash: kernel + boot script in the low 24 KiB (linker-enforced), then
# 38 blocks of 1 KiB each for classic BLOCK storage, addressed via the
# 0x08000000 base (the FPEC wants those addresses; reads work there too).

.equ RAM_END,     RAM_BASE + RAM_SIZE
.equ DSP_TOP,     RAM_END - 16
.equ RSP_TOP,     DSP_TOP - 256
.equ TIB_END,     RSP_TOP - 256
.equ TIB,         TIB_END - 128
.equ WORD_BUFFER, TIB - 48
.equ VARS,        WORD_BUFFER - 64
.equ BLK_BUFFER,  VARS - 1024

.equ var_STATE,   VARS + 0x00     # 0 = interpret, 1 = compile
.equ var_HERE,    VARS + 0x04     # next free dictionary cell
.equ var_LATEST,  VARS + 0x08     # most recently defined word header
.equ var_S0,      VARS + 0x0C     # data stack top address (for the S0 word)
.equ var_BASE,    VARS + 0x10     # number base
.equ var_KEYSRC,  VARS + 0x14     # boot-script read pointer; 0 = UART input
.equ var_CURRKEY, VARS + 0x18     # next unserved byte in the TIB
.equ var_BUFFTOP, VARS + 0x1C     # end of valid TIB data
.equ var_LASTCR,  VARS + 0x20     # 1 = last EOL was CR: swallow a following LF
.equ var_KEYEND,  VARS + 0x24     # end bound of the KEYSRC input source
# VARS+0x28..0x3C reserved

.equ BLOCKS_BASE, 0x08006000      # first block, 1 KiB each
.equ NUM_BLOCKS,  38              # 38 KiB: 0x08006000..0x0800F800

.equ F_IMMED,   0x80              # jonesforth header flags (same values)
.equ F_HIDDEN,  0x20
.equ F_LENMASK, 0x1f

.equ JONES_VERSION, 1

# Macros ---------------------------------------------------------------------

# NEXT: the indirect-threading pulse, appended to every primitive.
.macro NEXT
    lw a0, 0(s1)        # W = next codeword address from the thread
    addi s1, s1, 4      # advance IP
    lw t0, 0(a0)        # fetch through the code field
    jr t0               # execute
.endm

.macro PUSH reg         # push to the data stack
    addi sp, sp, -4
    sw \reg, 0(sp)
.endm

.macro POP reg          # pop from the data stack
    lw \reg, 0(sp)
    addi sp, sp, 4
.endm

.macro PUSHRSP reg      # push to the return stack
    addi s0, s0, -4
    sw \reg, 0(s0)
.endm

.macro POPRSP reg       # pop from the return stack
    lw \reg, 0(s0)
    addi s0, s0, 4
.endm

# Dictionary headers: link cell, flags+length byte, name, zero padding to a
# cell boundary, code field.  The original threads the chain automatically
# with a reassigned `link` symbol; RISC-V GAS refuses a redefined symbol in
# a relocation, so the link is an explicit argument (the previous word's
# label, NULL for the first) -- the same conclusion the fotrh port reached.
# The name length is computed by the assembler (9f - 8f) so the string is
# the single source of truth; GAS strips the quotes call sites pass, so the
# .ascii re-quotes (a lesson from the fotrh port).
.equ name_NULL, 0

.macro defcode name, label, link, flags=0
    .balign 4
    .globl name_\label
name_\label :
    .4byte name_\link
    .byte (9f - 8f) + \flags
8:  .ascii "\name"
9:  .balign 4, 0
    .globl \label
\label :
    .4byte code_\label
    .globl code_\label
code_\label :
.endm

.macro defword name, label, link, flags=0
    .balign 4
    .globl name_\label
name_\label :
    .4byte name_\link
    .byte (9f - 8f) + \flags
8:  .ascii "\name"
9:  .balign 4, 0
    .globl \label
\label :
    .4byte DOCOL        # body follows as .4byte list, ending with EXIT
.endm

.macro defvar name, label, link, addr, flags=0
    defcode \name, \label, \link, \flags
    li a1, \addr
    PUSH a1
    NEXT
.endm

.macro defconst name, label, link, value, flags=0
    defcode \name, \label, \link, \flags
    li a1, \value
    PUSH a1
    NEXT
.endm

# Messages (defined before use: their .equ lengths become addi immediates) --
msg_banner: .ascii "JONESFORTH RV32EC v1 (CH32V006)\r\n"
.equ MSG_BANNER_LEN, . - msg_banner
msg_ok:     .ascii " ok\r\n"
.equ MSG_OK_LEN, . - msg_ok
msg_q:      .ascii "? "
.equ MSG_Q_LEN, . - msg_q
msg_crlf:   .ascii "\r\n"
.equ MSG_CRLF_LEN, . - msg_crlf
msg_stack:  .ascii "? STACK\r\n"
.equ MSG_STACK_LEN, . - msg_stack
msg_skip:   .ascii "KEY held: boot script skipped\r\n"
.equ MSG_SKIP_LEN, . - msg_skip
msg_compile: .ascii "] "
.equ MSG_COMPILE_LEN, . - msg_compile

# Trap beacon ----------------------------------------------------------------
# Any trap prints 'T' <mcause> <mepc> in hex and hangs with state intact.
# 1 KiB alignment because QingKe cores mask low mtvec bits (fotrh lesson: an
# unaligned handler made every trap vector to 0x000 and look like a reboot).
    .balign 1024
trap_handler:
    li t0, UART_BASE_ADDRESS
    li t2, 'T'
beacon_putc:
    lw t1, UART_TX_STATUS(t0)
    andi t1, t1, UART_TX_BIT
    beqz t1, beacon_putc
    sw t2, UART_TX_DATA(t0)
    csrr a1, mcause
    li a3, 2                    # two passes: mcause, then mepc
beacon_word:
    li a2, 8                    # 8 hex nibbles
beacon_nibble:
    lw t1, UART_TX_STATUS(t0)
    andi t1, t1, UART_TX_BIT
    beqz t1, beacon_nibble
    srli t2, a1, 28
    addi t2, t2, '0'
    li t1, '9'
    ble t2, t1, beacon_digit
    addi t2, t2, 'A'-'9'-1
beacon_digit:
    sw t2, UART_TX_DATA(t0)
    slli a1, a1, 4
    addi a2, a2, -1
    bnez a2, beacon_nibble
    li t2, ' '
beacon_sep:
    lw t1, UART_TX_STATUS(t0)
    andi t1, t1, UART_TX_BIT
    beqz t1, beacon_sep
    sw t2, UART_TX_DATA(t0)
    csrr a1, mepc
    addi a3, a3, -1
    bnez a3, beacon_word
beacon_hang:
    j beacon_hang

interrupt_init:
    csrci mstatus, 0x8          # global interrupts off
    la t0, trap_handler         # (no mie clear: QingKe V2 has no mie CSR,
    csrw mtvec, t0              #  PFIC channels are all off at reset)
    ret

# I/O helpers ----------------------------------------------------------------
# Convention: uart_get/uart_put are leaves clobbering t0, t1 (+a0 as the
# character).  Multi-call helpers spill ra to the return stack (s0), which
# therefore must be live before the first call at boot (fotrh lesson).

uart_get:                       # ( -- a0=char ) blocking read
    li t0, UART_BASE_ADDRESS
1:  lw t1, UART_RX_STATUS(t0)
    andi t1, t1, UART_RX_BIT
    beqz t1, 1b
    lbu a0, UART_RX_DATA(t0)
    ret

uart_put:                       # ( a0=char -- ) blocking write
    li t0, UART_BASE_ADDRESS
1:  lw t1, UART_TX_STATUS(t0)
    andi t1, t1, UART_TX_BIT
    beqz t1, 1b
    sb a0, UART_TX_DATA(t0)
    ret

_puts:                          # print a1..a2; clobbers a0,a1,t0,t1
    addi s0, s0, -4
    sw ra, 0(s0)
1:  beq a1, a2, 2f
    lbu a0, 0(a1)
    call uart_put
    addi a1, a1, 1
    j 1b
2:  lw ra, 0(s0)
    addi s0, s0, 4
    ret

flash_unlock:                   # unlock FPEC for PG and fast-erase; boot-time
    li t0, FLASH_R_BASE
    li t1, FLASH_KEY1
    sw t1, FLASH_KEYR(t0)
    li t1, FLASH_KEY2
    sw t1, FLASH_KEYR(t0)
    li t1, FLASH_KEY1
    sw t1, FLASH_MODEKEYR(t0)
    li t1, FLASH_KEY2
    sw t1, FLASH_MODEKEYR(t0)
    ret

# _KEY: one input byte ------------------------------------------------------
# Source 1: the boot script in flash (KEYSRC != 0), ending at the first 0xFF
# byte (erased flash / the explicit sentinel after .incbin).  Source 2: the
# TIB, refilled line-by-line from the UART with echo and editing.
# Clobbers t0-t2 (and, via _refill, a1/a2 -- callers never keep a1/a2 live
# across a refill: every line ends in '\n', so no token spans two lines).

_KEY:
    addi s0, s0, -4
    sw ra, 0(s0)
    li t0, var_KEYSRC
    lw t1, 0(t0)
    beqz t1, key_interactive
    li t2, var_KEYEND           # source ends at its bound (a space-padded
    lw t2, 0(t2)                # block has no 0xFF terminator) ...
    bgeu t1, t2, key_src_end
    lbu a0, 0(t1)               # byte of boot script / LOADed block
    li t2, 0xFF
    beq a0, t2, key_src_end     # ... or at the first erased byte
    addi t1, t1, 1
    sw t1, 0(t0)
    j key_done
key_src_end:
    sw zero, 0(t0)              # boot script exhausted: switch to UART,
    li a0, '\n'                 # closing any open line
    j key_done
key_interactive:
    li t0, var_CURRKEY
    lw t1, 0(t0)
    li t2, var_BUFFTOP
    lw t2, 0(t2)
    bltu t1, t2, key_serve
    call _refill
    j key_interactive
key_serve:
    lbu a0, 0(t1)
    addi t1, t1, 1
    sw t1, 0(t0)
key_done:
    lw ra, 0(s0)
    addi s0, s0, 4
    ret

# _refill: read one edited line into the TIB.  Prints " ok" first when in
# interpret state (a departure from jonesforth's silent stdin, kept tiny).
# Handles backspace and DEL, ignores other control characters and bare ESC
# (arrow-key tails still land in the buffer; harmless, fix with the editor).
_refill:
    addi s0, s0, -4
    sw ra, 0(s0)
    li t0, var_STATE
    lw t0, 0(t0)
    bnez t0, refill_compiling
    la a1, msg_ok
    addi a2, a1, MSG_OK_LEN
    call _puts
    j refill_read
refill_compiling:
    la a1, msg_compile          # "] ": make compile state visible -- a
    addi a2, a1, MSG_COMPILE_LEN # dangling ':' otherwise looks like a dead
    call _puts                  # console (learned the hard way)
refill_read:
    li a2, TIB                  # a2 = write pointer (safe across uart_get/put)
refill_loop:
    call uart_get
    li t0, '\n'
    beq a0, t0, refill_lf
    li t1, var_LASTCR           # any non-LF byte breaks a CR-LF pair
    sw zero, 0(t1)
    li t0, '\r'
    beq a0, t0, refill_cr
    li t0, 0x08                 # backspace
    beq a0, t0, refill_bs
    li t0, 0x7F                 # DEL (most terminals send this for backspace)
    beq a0, t0, refill_bs
    li t0, ' '
    bltu a0, t0, refill_loop    # ignore other control chars (incl. bare ESC)
    li t0, TIB_END - 1
    bgeu a2, t0, refill_loop    # line full: drop further input till EOL
    sb a0, 0(a2)
    addi a2, a2, 1
    call uart_put               # echo
    j refill_loop
refill_bs:
    li t0, TIB
    beq a2, t0, refill_loop     # nothing to erase
    addi a2, a2, -1
    li a0, 0x08
    call uart_put
    li a0, ' '
    call uart_put
    li a0, 0x08
    call uart_put
    j refill_loop
refill_lf:
    li t0, var_LASTCR           # LF right after a CR-terminated line is the
    lw t1, 0(t0)                # second half of a CRLF pair: swallow it, so
    beqz t1, refill_eol         # CRLF terminals don't produce phantom empty
    sw zero, 0(t0)              # lines (a bare LF still ends a line)
    j refill_loop
refill_cr:
    li t0, var_LASTCR
    li t1, 1
    sw t1, 0(t0)
refill_eol:
    li a0, '\r'
    call uart_put
    li a0, '\n'
    call uart_put
    li t0, '\n'                 # terminate the line in the buffer: WORD's
    sb t0, 0(a2)                # delimiter logic relies on it
    addi a2, a2, 1
    li t0, var_BUFFTOP
    sw a2, 0(t0)
    li t0, var_CURRKEY
    li t1, TIB
    sw t1, 0(t0)
    lw ra, 0(s0)
    addi s0, s0, 4
    ret

# _WORD: parse the next whitespace-delimited token -> a0 = WORD_BUFFER,
# a1 = length (capped at 31).  Skips \ comments to end of line, exactly like
# the original.  Clobbers t0, t1, a2 (+_KEY's clobbers).
_WORD:
    addi s0, s0, -4
    sw ra, 0(s0)
word_skip:
    call _KEY
    li t0, '\\'
    beq a0, t0, word_comment
    li t0, ' '
    bleu a0, t0, word_skip      # space and all control chars delimit
    li a2, WORD_BUFFER
word_collect:
    li t1, WORD_BUFFER + 31
    bgeu a2, t1, word_key       # cap the name; excess bytes are consumed
    sb a0, 0(a2)
    addi a2, a2, 1
word_key:
    call _KEY
    li t0, ' '
    bgtu a0, t0, word_collect
    li a0, WORD_BUFFER
    sub a1, a2, a0
    lw ra, 0(s0)
    addi s0, s0, 4
    ret
word_comment:
    call _KEY
    li t0, '\n'
    bne a0, t0, word_comment
    j word_skip

# _NUMBER: parse a0..a0+a1 in the current BASE -> a0 = value, a1 = number of
# unparsed characters (0 = clean parse; the caller treats nonzero as error,
# same contract as the original).  Leading '-' negates.  Digits are
# 0-9 then A-Z (uppercase, faithful to jonesforth).
# Clobbers t0-t2, a2, tp.
_NUMBER:
    beqz a1, number_done0
    mv t2, a0                   # t2 = read pointer
    li t0, var_BASE
    lw t0, 0(t0)                # t0 = base
    li a0, 0                    # a0 = negative flag for now
    lbu t1, 0(t2)
    li a2, '-'
    bne t1, a2, number_digits0
    li a0, 1
    addi t2, t2, 1
    addi a1, a1, -1
    bnez a1, number_digits0
    li a1, 1                    # a lone '-' is not a number
    li a0, 0
    ret
number_digits0:
    li a2, 0                    # a2 = accumulator
number_digits:
    lbu t1, 0(t2)
    addi t1, t1, -'0'
    bltz t1, number_finish      # below '0': stop
    li tp, 10
    bltu t1, tp, number_range
    addi t1, t1, -('A'-'0')     # letter digits: 'A' -> 10
    bltz t1, number_finish      # between '9' and 'A': stop
    addi t1, t1, 10
number_range:
    bge t1, t0, number_finish   # digit >= BASE: stop
    mul a2, a2, t0
    add a2, a2, t1
    addi t2, t2, 1
    addi a1, a1, -1
    bnez a1, number_digits
number_finish:
    beqz a0, number_pos
    neg a2, a2
number_pos:
    mv a0, a2
    ret                         # a1 = unparsed count (0 on full parse)
number_done0:
    li a0, 0
    ret

# _FIND: a0 = name address, a1 = length -> a0 = header address or 0.
# Compares length+F_HIDDEN in one masked byte (hidden words can never match)
# then the name bytes, exactly like the original.  Clobbers t0-t2, a2, gp, tp.
_FIND:
    li t2, var_LATEST
    lw t2, 0(t2)
find_loop:
    beqz t2, find_missing
    lbu t0, 4(t2)
    andi t0, t0, F_HIDDEN | F_LENMASK
    bne t0, a1, find_next
    mv tp, a0                   # compare names byte by byte
    addi a2, t2, 5
    mv t1, a1
find_cmp:
    beqz t1, find_found
    lbu t0, 0(a2)
    lbu gp, 0(tp)
    bne t0, gp, find_next
    addi a2, a2, 1
    addi tp, tp, 1
    addi t1, t1, -1
    j find_cmp
find_next:
    lw t2, 0(t2)
    j find_loop
find_found:
    mv a0, t2
    ret
find_missing:
    li a0, 0
    ret

# _TCFA: a0 = header address -> a0 = code field address.
# Skip the link (4), the flags+length byte (1), the name, then align up.
_TCFA:
    lbu t0, 4(a0)
    andi t0, t0, F_LENMASK
    add a0, a0, t0
    addi a0, a0, 4+1+3
    andi a0, a0, -4
    ret

# _COMMA: append cell a0 at HERE.  Clobbers t0, t1.
_COMMA:
    li t0, var_HERE
    lw t1, 0(t0)
    sw a0, 0(t1)
    addi t1, t1, 4
    sw t1, 0(t0)
    ret

# Boot -----------------------------------------------------------------------
boot:
    li s0, RSP_TOP              # RSP first: helpers spill ra through it
    call interrupt_init
    call uart_init
    call gpio_init
    call flash_unlock
    # Forth variables
    li t0, var_STATE
    sw zero, 0(t0)
    li t0, var_HERE
    li t1, RAM_BASE
    sw t1, 0(t0)
    li t0, var_LATEST
    la t1, name_FPPROG          # the last builtin defined below: keep it last!
    sw t1, 0(t0)
    li t0, var_S0
    li t1, DSP_TOP
    sw t1, 0(t0)
    li t0, var_BASE
    li t1, 10
    sw t1, 0(t0)
    li t0, var_CURRKEY          # TIB starts out empty
    li t1, TIB
    sw t1, 0(t0)
    li t0, var_BUFFTOP
    sw t1, 0(t0)
    li t0, var_LASTCR
    sw zero, 0(t0)
    # Boot script escape hatch: hold any key in the terminal while the board
    # resets and the script is skipped -- the recovery path for a broken
    # startup screen in block 1.  A ~40 ms window is polled for a received
    # byte.  (This replaced a PD4 button check: real boards turned out to
    # drive PD4 high at reset, silently skipping the script every boot; the
    # UART is the one peripheral every setup already has.)
    la t2, _initscript
    li t0, UART_BASE_ADDRESS
    li a3, 150000               # ~40 ms at 24 MHz, ~7 cycles per iteration
boot_keywait:
    lw t1, UART_RX_STATUS(t0)
    andi t1, t1, UART_RX_BIT
    bnez t1, boot_key_skip
    addi a3, a3, -1
    bnez a3, boot_keywait
    j boot_arm
boot_key_skip:
    lbu t1, UART_RX_DATA(t0)    # consume the held key
    li t2, 0                    # and disarm the boot script
boot_arm:
    li t0, var_KEYSRC
    sw t2, 0(t0)
    li t0, var_KEYEND           # the script can never overrun the kernel
    li t1, 0x6000               # flash region (LOAD sets its own bound)
    sw t1, 0(t0)
    # Banner, then enter the threaded interpreter
    la a1, msg_banner
    addi a2, a1, MSG_BANNER_LEN
    call _puts
    li t0, var_KEYSRC           # say so when the escape hatch fired: a
    lw t0, 0(t0)                # silently skipped boot script cost us a
    bnez t0, boot_go            # debugging round on real hardware
    la a1, msg_skip
    addi a2, a1, MSG_SKIP_LEN
    call _puts
boot_go:
    li sp, DSP_TOP
    la s1, cold_start
    NEXT

    .balign 4
cold_start:                     # jonesforth's trick: the first thread
    .4byte QUIT

# Primitives -----------------------------------------------------------------
# Same order as jonesforth.S: stack juggling, arithmetic, comparisons (1/0
# booleans!), bitwise, memory, variables/constants, return stack, I/O, then
# the compiler words.

defcode "DROP", DROP, NULL
    addi sp, sp, 4
    NEXT

defcode "SWAP", SWAP, DROP
    lw t0, 0(sp)
    lw t1, 4(sp)
    sw t0, 4(sp)
    sw t1, 0(sp)
    NEXT

defcode "DUP", DUP, SWAP
    lw t0, 0(sp)
    PUSH t0
    NEXT

defcode "OVER", OVER, DUP
    lw t0, 4(sp)
    PUSH t0
    NEXT

defcode "ROT", ROT, OVER# ( a b c -- b c a )
    lw t0, 0(sp)                # c
    lw t1, 4(sp)                # b
    lw t2, 8(sp)                # a
    sw t2, 0(sp)
    sw t0, 4(sp)
    sw t1, 8(sp)
    NEXT

defcode "-ROT", NROT, ROT# ( a b c -- c a b )
    lw t0, 0(sp)                # c
    lw t1, 4(sp)                # b
    lw t2, 8(sp)                # a
    sw t1, 0(sp)
    sw t2, 4(sp)
    sw t0, 8(sp)
    NEXT

defcode "2DROP", TWODROP, NROT
    addi sp, sp, 8
    NEXT

defcode "2DUP", TWODUP, TWODROP
    lw t0, 0(sp)
    lw t1, 4(sp)
    PUSH t1
    PUSH t0
    NEXT

defcode "2SWAP", TWOSWAP, TWODUP# ( a b c d -- c d a b )
    lw t0, 0(sp)                # d
    lw t1, 4(sp)                # c
    lw t2, 8(sp)                # b
    lw a1, 12(sp)               # a
    sw t2, 0(sp)
    sw a1, 4(sp)
    sw t0, 8(sp)
    sw t1, 12(sp)
    NEXT

defcode "?DUP", QDUP, TWOSWAP
    lw t0, 0(sp)
    beqz t0, 1f
    PUSH t0
1:  NEXT

defcode "1+", INCR, QDUP
    lw t0, 0(sp)
    addi t0, t0, 1
    sw t0, 0(sp)
    NEXT

defcode "1-", DECR, INCR
    lw t0, 0(sp)
    addi t0, t0, -1
    sw t0, 0(sp)
    NEXT

defcode "4+", INCR4, DECR
    lw t0, 0(sp)
    addi t0, t0, 4
    sw t0, 0(sp)
    NEXT

defcode "4-", DECR4, INCR4
    lw t0, 0(sp)
    addi t0, t0, -4
    sw t0, 0(sp)
    NEXT

defcode "+", ADD, DECR4
    POP t0
    lw t1, 0(sp)
    add t1, t1, t0
    sw t1, 0(sp)
    NEXT

defcode "-", SUB, ADD
    POP t0
    lw t1, 0(sp)
    sub t1, t1, t0
    sw t1, 0(sp)
    NEXT

defcode "*", MUL, SUB# Zmmul: low 32 bits, same as the original
    POP t0
    lw t1, 0(sp)
    mul t1, t1, t0
    sw t1, 0(sp)
    NEXT

# /MOD ( a b -- r q ): software division, x86-idiv sign semantics so that
# jonesforth.f's / MOD U. etc. behave identically to the original.
defcode "/MOD", DIVMOD, MUL
    POP a2                      # b (divisor)
    POP a1                      # a (dividend)
    srai t2, a1, 31             # t2 = dividend sign mask (survives the loop)
    srai tp, a2, 31
    xor gp, t2, tp              # gp = quotient sign mask
    xor a1, a1, t2              # absolute values
    sub a1, a1, t2
    xor a2, a2, tp
    sub a2, a2, tp
    beqz a2, divmod_zero
    li a0, 0                    # quotient
    li t0, 0                    # remainder
    li t1, 32
divmod_loop:
    slli t0, t0, 1              # restoring division, one bit per pass
    srli tp, a1, 31
    or t0, t0, tp
    slli a1, a1, 1
    slli a0, a0, 1
    bltu t0, a2, 1f
    sub t0, t0, a2
    ori a0, a0, 1
1:  addi t1, t1, -1
    bnez t1, divmod_loop
    beqz gp, 2f
    neg a0, a0
2:  beqz t2, 3f
    neg t0, t0
3:  PUSH t0                     # remainder
    PUSH a0                     # quotient
    NEXT
divmod_zero:                    # divide by zero: 0 0 (the x86 would fault)
    PUSH zero
    PUSH zero
    NEXT

# Comparisons: jonesforth's deliberate 1/0 booleans, not ANS Forth's -1/0.
defcode "=", EQU, DIVMOD
    POP t0
    POP t1
    sub t0, t1, t0
    seqz t0, t0
    PUSH t0
    NEXT

defcode "<>", NEQU, EQU
    POP t0
    POP t1
    sub t0, t1, t0
    snez t0, t0
    PUSH t0
    NEXT

defcode "<", LT, NEQU
    POP t0
    POP t1
    slt t2, t1, t0
    PUSH t2
    NEXT

defcode ">", GT, LT
    POP t0
    POP t1
    slt t2, t0, t1
    PUSH t2
    NEXT

defcode "<=", LE, GT
    POP t0
    POP t1
    slt t2, t0, t1
    xori t2, t2, 1
    PUSH t2
    NEXT

defcode ">=", GE, LE
    POP t0
    POP t1
    slt t2, t1, t0
    xori t2, t2, 1
    PUSH t2
    NEXT

defcode "0=", ZEQU, GE
    lw t0, 0(sp)
    seqz t0, t0
    sw t0, 0(sp)
    NEXT

defcode "0<>", ZNEQU, ZEQU
    lw t0, 0(sp)
    snez t0, t0
    sw t0, 0(sp)
    NEXT

defcode "0<", ZLT, ZNEQU
    lw t0, 0(sp)
    slt t0, t0, zero
    sw t0, 0(sp)
    NEXT

defcode "0>", ZGT, ZLT
    lw t0, 0(sp)
    slt t0, zero, t0
    sw t0, 0(sp)
    NEXT

defcode "0<=", ZLE, ZGT
    lw t0, 0(sp)
    slt t0, zero, t0
    xori t0, t0, 1
    sw t0, 0(sp)
    NEXT

defcode "0>=", ZGE, ZLE
    lw t0, 0(sp)
    slt t0, t0, zero
    xori t0, t0, 1
    sw t0, 0(sp)
    NEXT

defcode "AND", AND, ZGE
    POP t0
    lw t1, 0(sp)
    and t1, t1, t0
    sw t1, 0(sp)
    NEXT

defcode "OR", OR, AND
    POP t0
    lw t1, 0(sp)
    or t1, t1, t0
    sw t1, 0(sp)
    NEXT

defcode "XOR", XOR, OR
    POP t0
    lw t1, 0(sp)
    xor t1, t1, t0
    sw t1, 0(sp)
    NEXT

defcode "INVERT", INVERT, XOR
    lw t0, 0(sp)
    xori t0, t0, -1
    sw t0, 0(sp)
    NEXT

# Inner interpreter ----------------------------------------------------------

defcode "EXIT", EXIT, INVERT
    POPRSP s1
    NEXT

defcode "LIT", LIT, EXIT
    lw t0, 0(s1)
    addi s1, s1, 4
    PUSH t0
    NEXT

# Memory ---------------------------------------------------------------------

defcode "!", STORE, LIT# ( value addr -- )
    POP t0
    POP t1
    sw t1, 0(t0)
    NEXT

defcode "@", FETCH, STORE# ( addr -- value )
    lw t0, 0(sp)
    lw t0, 0(t0)
    sw t0, 0(sp)
    NEXT

defcode "+!", ADDSTORE, FETCH# ( amount addr -- )
    POP t0
    POP t1
    lw t2, 0(t0)
    add t2, t2, t1
    sw t2, 0(t0)
    NEXT

defcode "-!", SUBSTORE, ADDSTORE# ( amount addr -- )
    POP t0
    POP t1
    lw t2, 0(t0)
    sub t2, t2, t1
    sw t2, 0(t0)
    NEXT

defcode "C!", STOREBYTE, SUBSTORE# ( value addr -- )
    POP t0
    POP t1
    sb t1, 0(t0)
    NEXT

defcode "C@", FETCHBYTE, STOREBYTE# ( addr -- value )
    lw t0, 0(sp)
    lbu t0, 0(t0)
    sw t0, 0(sp)
    NEXT

defcode "C@C!", CCOPY, FETCHBYTE# ( src dst -- src+1 dst+1 ) block-copy helper
    lw t0, 0(sp)                # dst
    lw t1, 4(sp)                # src
    lbu t2, 0(t1)
    sb t2, 0(t0)
    addi t0, t0, 1
    addi t1, t1, 1
    sw t0, 0(sp)
    sw t1, 4(sp)
    NEXT

defcode "CMOVE", CMOVE, CCOPY# ( src dst len -- )
    POP t0                      # len
    POP t1                      # dst
    POP t2                      # src
1:  beqz t0, 2f
    lbu a1, 0(t2)
    sb a1, 0(t1)
    addi t2, t2, 1
    addi t1, t1, 1
    addi t0, t0, -1
    j 1b
2:  NEXT

# Builtin variables and constants -------------------------------------------

defvar "STATE", STATE, CMOVE,  var_STATE
defvar "HERE", HERE, STATE,   var_HERE
defvar "LATEST", LATEST, HERE, var_LATEST
defvar "S0", SZ, LATEST,     var_S0
defvar "BASE", BASE, SZ,   var_BASE

defconst "VERSION", VERSION, BASE,    JONES_VERSION
defconst "R0", RZ, VERSION,         RSP_TOP
defcode "DOCOL", __DOCOL, RZ# pushes an address symbol: la, not li
    la a1, DOCOL
    PUSH a1
    NEXT
defconst "F_IMMED", __F_IMMED, __DOCOL,  F_IMMED
defconst "F_HIDDEN", __F_HIDDEN, __F_IMMED, F_HIDDEN
defconst "F_LENMASK", __F_LENMASK, __F_HIDDEN, F_LENMASK
# Instead of SYS_* and SYSCALLn: the flash geometry for BLOCK (in Forth)
# ("NBLOCKS" not the classic "#BLOCKS": '#' starts a GAS comment even inside
#  a macro argument)
defconst "BLOCKS", BLOCKS, __F_LENMASK,     BLOCKS_BASE
defconst "NBLOCKS", NBLOCKS, BLOCKS,    NUM_BLOCKS
defconst "BLKBUF", BLKBUFC, NBLOCKS,    BLK_BUFFER
# The input-source pointer and its end bound, exposed so LOAD (in Forth)
# can redirect KEY to a block in flash; reading stops at the bound or at the
# first 0xFF byte (erased flash), then hands input back to the UART.
defvar "KEYSRC", KEYSRCV, BLKBUFC, var_KEYSRC
defvar "KEYEND", KEYENDV, KEYSRCV, var_KEYEND

# Return stack ---------------------------------------------------------------

defcode ">R", TOR, KEYENDV
    POP t0
    PUSHRSP t0
    NEXT

defcode "R>", FROMR, TOR
    POPRSP t0
    PUSH t0
    NEXT

defcode "RSP@", RSPFETCH, FROMR
    PUSH s0
    NEXT

defcode "RSP!", RSPSTORE, RSPFETCH
    POP s0
    NEXT

defcode "RDROP", RDROP, RSPSTORE
    addi s0, s0, 4
    NEXT

defcode "DSP@", DSPFETCH, RDROP
    mv t0, sp
    PUSH t0
    NEXT

defcode "DSP!", DSPSTORE, DSPFETCH
    POP t0
    mv sp, t0
    NEXT

# I/O ------------------------------------------------------------------------

defcode "KEY", KEY, DSPSTORE
    call _KEY
    PUSH a0
    NEXT

defcode "EMIT", EMIT, KEY
    POP a0
    call uart_put
    NEXT

defcode "WORD", WORD, EMIT
    call _WORD
    PUSH a0                     # buffer address
    PUSH a1                     # length
    NEXT

defcode "NUMBER", NUMBER, WORD
    POP a1
    POP a0
    call _NUMBER
    PUSH a0                     # value
    PUSH a1                     # unparsed count
    NEXT

defcode "TELL", TELL, NUMBER# ( addr len -- ) print a string
    POP a2
    POP a1
    add a2, a1, a2
1:  beq a1, a2, 2f
    lbu a0, 0(a1)
    call uart_put
    addi a1, a1, 1
    j 1b
2:  NEXT

# Dictionary lookups ---------------------------------------------------------

defcode "FIND", FIND, TELL
    POP a1
    POP a0
    call _FIND
    PUSH a0
    NEXT

defcode ">CFA", TCFA, FIND
    POP a0
    call _TCFA
    PUSH a0
    NEXT

defword ">DFA", TDFA, TCFA
    .4byte TCFA, INCR4, EXIT

# Compiling ------------------------------------------------------------------

# DOCOL: the interpreter for colon definitions.  Not a dictionary word: the
# codeword of every defword points here; W (a0) holds that codeword address.
    .balign 4
    .globl DOCOL
DOCOL:
    PUSHRSP s1
    addi s1, a0, 4
    NEXT

defcode "CREATE", CREATE, TDFA# ( addr len -- ) build a header at HERE
    POP a1                      # length
    POP a0                      # name address
    li t0, var_HERE
    lw t1, 0(t0)                # t1 = new header address
    li t2, var_LATEST
    lw a2, 0(t2)
    sw a2, 0(t1)                # link -> previous latest
    sw t1, 0(t2)                # LATEST -> this header
    sb a1, 4(t1)                # flags+length byte (flags 0)
    addi a2, t1, 5              # copy the name
1:  beqz a1, 2f
    lbu t2, 0(a0)
    sb t2, 0(a2)
    addi a0, a0, 1
    addi a2, a2, 1
    addi a1, a1, -1
    j 1b
2:  andi t2, a2, 3              # zero-pad to the cell boundary
    beqz t2, 4f
3:  sb zero, 0(a2)
    addi a2, a2, 1
    andi t2, a2, 3
    bnez t2, 3b
4:  sw a2, 0(t0)                # HERE = aligned end (the code field goes next)
    NEXT

defcode ",", COMMA, CREATE
    POP a0
    call _COMMA
    NEXT

defcode "[", LBRAC, COMMA, F_IMMED
    li t0, var_STATE
    sw zero, 0(t0)
    NEXT

defcode "]", RBRAC, LBRAC
    li t0, var_STATE
    li t1, 1
    sw t1, 0(t0)
    NEXT

defword ":", COLON, RBRAC
    .4byte WORD                 # get the name
    .4byte CREATE               # build the header
    .4byte LIT, DOCOL, COMMA    # code field: DOCOL
    .4byte LATEST, FETCH, HIDDEN # hide it while it is being compiled
    .4byte RBRAC                # compile mode
    .4byte EXIT

defword ";", SEMICOLON, COLON, F_IMMED
    .4byte LIT, EXIT, COMMA     # append EXIT
    .4byte LATEST, FETCH, HIDDEN # unhide
    .4byte LBRAC                # back to interpret mode
    .4byte EXIT

defcode "IMMEDIATE", IMMEDIATE, SEMICOLON, F_IMMED
    li t0, var_LATEST
    lw t0, 0(t0)
    lbu t1, 4(t0)
    xori t1, t1, F_IMMED
    sb t1, 4(t0)
    NEXT

defcode "HIDDEN", HIDDEN, IMMEDIATE# ( entry -- ) toggle the hidden flag
    POP t0
    lbu t1, 4(t0)
    xori t1, t1, F_HIDDEN
    sb t1, 4(t0)
    NEXT

defword "HIDE", HIDE, HIDDEN
    .4byte WORD, FIND, HIDDEN, EXIT

defcode "'", TICK, HIDE# works compiled, like the original (lodsl)
    lw t0, 0(s1)
    addi s1, s1, 4
    PUSH t0
    NEXT

# Branching: offsets are relative to the offset cell itself.
defcode "BRANCH", BRANCH, TICK
    lw t0, 0(s1)
    add s1, s1, t0
    NEXT

defcode "0BRANCH", ZBRANCH, BRANCH
    POP t0
    beqz t0, code_BRANCH        # flag is zero: take the branch
    addi s1, s1, 4              # otherwise skip the offset cell
    NEXT

defcode "LITSTRING", LITSTRING, ZBRANCH
    lw t0, 0(s1)                # length cell
    addi s1, s1, 4
    PUSH s1                     # address of the string data
    PUSH t0
    add s1, s1, t0              # skip the string, realigning IP
    addi s1, s1, 3              # (misaligned IP would trap on QingKe V2)
    andi s1, s1, -4
    NEXT

defcode "CHAR", CHAR, LITSTRING
    call _WORD
    lbu t0, 0(a0)
    PUSH t0
    NEXT

defcode "EXECUTE", EXECUTE, CHAR
    POP a0                      # W = codeword address, as DOCOL expects
    lw t0, 0(a0)
    jr t0                       # that word's NEXT/EXIT continues the thread

defword "QUIT", QUIT, EXECUTE
    .4byte RZ, RSPSTORE         # clear the return stack
    .4byte INTERPRET
    .4byte BRANCH, -8           # loop forever

# INTERPRET: the outer interpreter, one word per call ------------------------
# Register use across helper calls: a4/a5 = parsed word, a3 = flags byte,
# tp = xt, gp = parsed number (helpers preserve what they don't document).
defcode "INTERPRET", INTERPRET, QUIT
    li t0, DSP_TOP              # catch data stack underflow from the last
    bleu sp, t0, interpret_word # word before it walks past the red zone
    la a1, msg_stack
    addi a2, a1, MSG_STACK_LEN
    call _puts
    li sp, DSP_TOP
interpret_word:
    call _WORD
    mv a4, a0
    mv a5, a1
    call _FIND
    beqz a0, interpret_number
    lbu a3, 4(a0)               # flags+length of the found word
    call _TCFA
    mv tp, a0
    andi t0, a3, F_IMMED
    bnez t0, interpret_execute  # immediate words always execute
    li t0, var_STATE
    lw t0, 0(t0)
    beqz t0, interpret_execute
    mv a0, tp                   # compiling: append the xt
    call _COMMA
    NEXT
interpret_execute:
    mv a0, tp                   # W = codeword address
    lw t0, 0(a0)
    jr t0
interpret_number:
    mv a0, a4
    mv a1, a5
    call _NUMBER
    bnez a1, interpret_error
    mv gp, a0
    li t0, var_STATE
    lw t0, 0(t0)
    beqz t0, interpret_push
    la a0, LIT                  # compiling: append LIT <value>
    call _COMMA
    mv a0, gp
    call _COMMA
    NEXT
interpret_push:
    PUSH gp
    NEXT
interpret_error:                # "? <word>" -- then carry on, like jonesforth
    la a1, msg_q
    addi a2, a1, MSG_Q_LEN
    call _puts
    mv a1, a4
    add a2, a4, a5
    call _puts
    la a1, msg_crlf
    addi a2, a1, MSG_CRLF_LEN
    call _puts
    NEXT

# Flash primitives (in place of jonesforth's SYSCALLn) -----------------------
# The FPEC stays unlocked from boot.  BLOCK/BUFFER/UPDATE/FLUSH are built on
# these two words in Forth (see boot.f / the blocks screen).

defcode "FERASE", FERASE, INTERPRET# ( addr -- ) fast-erase one 64-byte page
    POP a1
    li t0, FLASH_R_BASE
1:  lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, 1b
    li t1, FLASH_CTLR_FTER
    sw t1, FLASH_CTLR(t0)
    sw a1, FLASH_ADDR(t0)
    li t1, FLASH_CTLR_FTER | FLASH_CTLR_STRT
    sw t1, FLASH_CTLR(t0)
2:  lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, 2b
    sw zero, FLASH_CTLR(t0)
    NEXT

# FPPROG must stay the LAST definition: boot initialises LATEST to it.
# Fast page programming, the ch32fun-proven sequence: reset the 64-byte page
# buffer, latch 16 words into it (write each word to its flash address, then
# strobe BUFLOAD), then program the whole page with STRT.  The standard
# halfword PG mode is deliberately NOT used: on the CH32V006 it corrupted
# consecutive halfwords (observed on silicon: bytes ANDed across neighbours).
defcode "FPPROG", FPPROG, FERASE# ( src fa -- ) program a 64-byte page from RAM
    POP a1                      # fa: flash page address (64-aligned, 0x08...)
    POP a2                      # src: RAM address (word-aligned)
    li t0, FLASH_R_BASE
1:  lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, 1b
    li t1, FLASH_CTLR_FTPG
    sw t1, FLASH_CTLR(t0)       # fast page program mode
    li t1, FLASH_CTLR_FTPG | FLASH_CTLR_BUFRST
    sw t1, FLASH_CTLR(t0)       # reset the page buffer
2:  lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, 2b
    li a3, 16                   # 16 words fill the 64-byte buffer
3:  lw t2, 0(a2)
    sw t2, 0(a1)                # write the word to its flash address...
    li t1, FLASH_CTLR_FTPG | FLASH_CTLR_BUFLOAD
    sw t1, FLASH_CTLR(t0)       # ...and latch it into the page buffer
4:  lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, 4b
    addi a2, a2, 4
    addi a1, a1, 4
    addi a3, a3, -1
    bnez a3, 3b
    addi a1, a1, -64            # back to the page base
    sw a1, FLASH_ADDR(t0)
    li t1, FLASH_CTLR_FTPG | FLASH_CTLR_STRT
    sw t1, FLASH_CTLR(t0)       # program the page
5:  lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, 5b
    sw zero, FLASH_CTLR(t0)
    NEXT

# Boot script ----------------------------------------------------------------
# Plain Forth source, interpreted through _KEY before the UART takes over.
# The 0xFF sentinel ends it even if the flash beyond holds stale data.
    .section .bootf, "a"
    .globl _initscript
_initscript:
    .incbin "boot.f"
    .byte 0xFF
