#!/usr/bin/env python3
"""Emulator tests for jonesforth RV32EC.

Boots jonesforth.bin once in the RV32EC emulator (inherited from the fotrh
port), snapshots the booted state, and runs each interactive session against
a clone.  Any silicon-modelled fault (misaligned access, bad FPEC sequence,
RV32E register use) fails the test.  The persistence tests verify BLOCK
storage end-to-end, including across a simulated reset.
"""
import copy
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rv32emu import Emu

FLASH = open(os.path.join(HERE, "..", "jonesforth.bin"), "rb").read()

VAR_KEYSRC = 0x1D14  # var_KEYSRC offset within RAM


def boot(flash=FLASH, uart=b"", max_steps=40_000_000):
    """Run until the boot script is done and the interpreter idles."""
    e = Emu(flash, uart)
    done = 0
    prev_out = -1
    try:
        for _ in range(max_steps // 100_000):
            for _ in range(100_000):
                e.step()
            keysrc = int.from_bytes(e.ram[VAR_KEYSRC:VAR_KEYSRC + 4], "little")
            # booted = banner is out, input source is back on the UART, and
            # output has settled -- KEYSRC alone reads 0 during the boot-time
            # key-wait window, before the script is even armed
            if keysrc == 0 and e.uart_out and len(e.uart_out) == prev_out:
                done += 1
                if done >= 2:
                    break
            else:
                done = 0
            prev_out = len(e.uart_out)
    except RuntimeError:
        pass
    return e


def session(booted, text, steps=6_000_000):
    e = copy.deepcopy(booted)
    e.uart_in = list(text.encode())
    e.trace, e.stores, e.fault = [], [], None
    try:
        for _ in range(steps):
            e.step()
    except RuntimeError:
        pass
    return e


def out(e):
    return bytes(e.uart_out).decode("latin1")


failures = 0


def check(name, e, *substrings, absent=()):
    global failures
    text = out(e)
    problems = []
    if e.fault is not None:
        problems.append(f"fault={e.fault}")
    for s in substrings:
        if s not in text:
            problems.append(f"missing {s!r}")
    for s in absent:
        if s in text:
            problems.append(f"unexpected {s!r}")
    if not problems:
        print(f"PASS {name}")
    else:
        failures += 1
        print(f"FAIL {name}: {'; '.join(problems)}")
        print(f"  out: {text[-300:]!r}")
        print(f"  pc trace: {[hex(p) for p in e.trace[-12:]]}")


print("booting...")
B = boot()
check("boot-banner", B, "JONESFORTH RV32EC v1 (CH32V006)", absent=("? ",))

# Core interpreter ------------------------------------------------------------
e = session(B, "65 EMIT\n")
check("emit", e, "65 EMIT\r\nA")

e = session(B, ": STAR 42 EMIT ; STAR STAR\n")
check("colon-def", e, "**")

e = session(B, "7 2 /MOD 48 + EMIT 48 + EMIT\n")
check("divmod", e, "31")

e = session(B, "-7 2 /MOD NEGATE 48 + EMIT NEGATE 48 + EMIT\n")
check("divmod-neg", e, "31")

e = session(B, "FROB 66 EMIT\n")
check("parse-error", e, "? FROB", "B")

e = session(B, "DROP 67 EMIT\n")
check("underflow-guard", e, "? STACK", "C")

e = session(B, "3 3 = 48 + EMIT\n")
check("booleans", e, "1")

e = session(B, ": TEN [ 5 5 + ] LITERAL ; TEN 48 + EMIT\n")
check("literal", e, "TEN 48 + EMIT\r\n:")

e = session(B, "68 \\ comment to end of line\nEMIT\n")
check("comment", e, "D")

# CRLF line endings (picocom --omap crcrlf) must not create phantom empty
# lines: no two consecutive prompts
e = session(B, "65 EMIT\r\n66 EMIT\r\n")
check("crlf", e, "A", "B", absent=(" ok\r\n ok",))

# Compile state shows a "] " prompt instead of " ok" (a dangling ':' must
# not look like a dead console), and closing the definition restores " ok"
e = session(B, ": FOO 42\nEMIT ;\nFOO\n")
check("compile-prompt", e, "] ", "*")

# boot.f words ---------------------------------------------------------------
e = session(B, "1234 . 45 NEGATE .\n")
check("dot", e, "1234 -45")

e = session(B, ": COUNTDOWN 5 BEGIN DUP . 1- DUP 0= UNTIL DROP ; COUNTDOWN\n")
check("begin-until", e, "5 4 3 2 1")

e = session(B, ": SIGN DUP 0< IF 45 EMIT ELSE 43 EMIT THEN DROP ; 5 SIGN -5 SIGN\n")
check("if-else", e, "+-")

e = session(B, "1 2 ( inline comment ) + .\n")
check("paren-comment", e, "3")

e = session(B, "VARIABLE X 7 X ! X @ .\n")
check("variable", e, "7")

# Flash primitives: erase a page, program it from RAM via the page buffer
e = session(B, "134242304 FERASE 16961 BLKBUF ! BLKBUF 134242304 FPPROG "
               "134242304 C@ EMIT 134242305 C@ EMIT\n")
check("flash-prog", e, "AB")

# BLOCK range guard: junk block numbers must not reach CMOVE (on hardware a
# wild read trapped with mcause=5)
e = session(B, "0 BLOCK DROP 99 BLOCK DROP 66 EMIT\n")
check("block-range-guard", e, "??", "B")

# BLOCK persistence ----------------------------------------------------------
# Write "66 EMIT" into block 2 through the buffer, FLUSH to flash, LOAD it.
text = "66 EMIT"
pokes = "".join(f"{ord(c)} BLKBUF {i} + C!\n" for i, c in enumerate(text))
e = session(B, f"2 BLOCK DROP\n{pokes}UPDATE FLUSH\n2 LOAD\n", steps=16_000_000)
check("block-flush-load", e, "\r\nB")

# The same flash image after a REBOOT: block 2 must still load.  This is the
# persistence claim, end to end.
B2 = boot(flash=bytes(e.f))
e2 = session(B2, "2 LOAD\n")
check("block-survives-reset", e2, "\r\nB")

# Auto-boot: a startup screen in block 1 runs with no input at all (boot.f
# ends with "1 LOAD").  Block 1 sits at flash offset 0x6000.
img = FLASH + b"\xFF" * (0x6000 - len(FLASH)) + b"70 EMIT"
B3 = boot(flash=img)
check("block1-autoboot", B3, "F")

# Screen editor: CLEAN/P a startup screen defining a word, FLUSH, reboot --
# the word must exist and run.  This is the "persistent words" workflow.
e = session(B, "1 BLOCK DROP CLEAN\n"
               "0 P : TWO 2 ;\n"
               "1 P TWO 40 + EMIT\n"
               "L\n"
               "FLUSH\n", steps=16_000_000)
check("editor-put-list", e, ": TWO 2 ;")
B5 = boot(flash=bytes(e.f))
check("editor-screen-boots", B5, "*")          # TWO 40 + = 42
e2 = session(B5, "TWO 63 + EMIT\n")
check("editor-word-persists", e2, "A")

# A space-padded screen must not run off into the next block: block 2 holds
# other source, which must NOT execute during block 1's LOAD.
img = (FLASH + b"\xFF" * (0x6000 - len(FLASH))
       + b"70 EMIT" + b" " * (1024 - 7) + b"71 EMIT")
B6 = boot(flash=img)
check("load-bounded", B6, "F", absent=("G", "? "))

# A key held during reset skips the boot script entirely (and says so):
# boot.f words are unknown
B4 = boot(uart=b" ")
e = session(B4, "CR\n")
check("skip-held-key", e, "KEY held: boot script skipped", "? CR")

# ...and the normal boot must NOT print the skip notice
check("no-skip-notice", B, absent=("KEY held",))

print(f"\n{'ALL PASS' if failures == 0 else f'{failures} FAILURES'}")
sys.exit(1 if failures else 0)
