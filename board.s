##
# CH32V006F8U6 (QFN20, 62 KiB Flash, 8 KiB SRAM)
#
# CH32V006 PORT: new board file. Only RAM_SIZE lives here; shrinking it from
# the Longan Nano's 20 KiB reshapes the whole memory map automatically via
# 01-variables-constants.s: three 256 B stacks (DSP/RSP/TIB), 5 variable
# cells, a 64-cell PAD, and the rest (~7.1 KiB) is the user dictionary.
##

.equ RAM_SIZE, 1024 * 8                 # 8 KiB
