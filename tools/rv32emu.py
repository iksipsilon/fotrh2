#!/usr/bin/env python3
# Minimal RV32EC + Zmmul + Zicsr emulator, just enough to run fiveforths.bin
# Flash at 0x00000000, 8K RAM at 0x20000000, USART1 at 0x40013800.
import sys

M32 = 0xFFFFFFFF
def sx(v, bits):
    if v & (1 << (bits-1)): v -= (1 << bits)
    return v

class Emu:
    def __init__(self, flash, uart_in):
        # pad with 0xFF: that is what erased flash reads, and the source-replay
        # log uses the first 0xFF byte as its end-of-log marker
        self.f = bytearray(flash) + bytearray([0xFF] * (0x10000 - len(flash)))
        self.ram = bytearray(8*1024)
        self.x = [0]*16
        self.pc = 0
        self.csr = {}
        self.uart_in = list(uart_in)
        self.uart_out = []
        self.trace = []          # ring buffer of (pc, instr_word)
        self.stores = []         # ring of (pc, addr, val)
        self.fault = None
        # FPEC (flash controller) model: KEYR/MODEKEYR unlock sequences,
        # fast 64-byte page erase (FTER+STRT) and fast page programming
        # (FTPG with BUFRST/BUFLOAD, AND-semantics like real flash). Wrong
        # sequences fault, so the emulator catches a botched unlock dance
        # the way it caught the alignment traps.  Standard halfword PG is
        # deliberately a fault: on real CH32V006 silicon it corrupted
        # consecutive halfwords (bytes ANDed across neighbours).
        self.fpec = {'lock': True, 'flock': True, 'ctlr': 0, 'faddr': 0,
                     'kstage': 0, 'mkstage': 0,
                     'buf': [0xFFFFFFFF] * 16, 'lastw': None}
        self.gpiod_in = 0        # GPIOD input pins (bit 4 = replay-skip button)

    def _flash_pa(self, a):
        # normalize a flash address (0x00000000 alias or 0x08000000 base)
        if 0x08000000 <= a < 0x08010000: return a - 0x08000000
        if a < 0x10000: return a
        return None

    def r8(self, a):
        if a < 0x10000: return self.f[a]
        if a >= 0x08000000 and a < 0x08010000: return self.f[a-0x08000000]
        if 0x20000000 <= a < 0x20002000: return self.ram[a-0x20000000]
        if a == 0x40013800:  # STATR: RXNE(5) if input pending, TXE(7) always
            return (1<<7) | ((1<<5) if self.uart_in else 0)
        if a == 0x40013804:  # DATAR read
            return (self.uart_in.pop(0) & 0xFF) if self.uart_in else 0
        if 0x40000000 <= a < 0x50000000: return 0
        self.fault = ("load", self.pc, a); raise RuntimeError()
    def r32(self, a):
        if a & 3:
            self.fault = ("misaligned-load", self.pc, a); raise RuntimeError()
        if a == 0x40013800:
            return (1<<7) | ((1<<5) if self.uart_in else 0)
        if a == 0x40013804:
            return (self.uart_in.pop(0) & 0xFF) if self.uart_in else 0
        if a == 0x40011408:  # GPIOD_INDR
            return self.gpiod_in
        if a == 0x4002200C:  # FLASH_STATR: never busy (ops complete instantly)
            return 0
        if a == 0x40022010:  # FLASH_CTLR
            return self.fpec['ctlr']
        return self.r8(a) | self.r8(a+1)<<8 | self.r8(a+2)<<16 | self.r8(a+3)<<24
    def r16(self, a):
        if a & 1:
            self.fault = ("misaligned-load16", self.pc, a); raise RuntimeError()
        return self.r8(a) | self.r8(a+1)<<8
    def w8(self, a, v):
        v &= 0xFF
        if 0x20000000 <= a < 0x20002000: self.ram[a-0x20000000] = v; return
        if a == 0x40013804: self.uart_out.append(v); return
        if 0x40000000 <= a < 0x50000000: return  # RCC/GPIO etc: ignore
        self.fault = ("store", self.pc, a); raise RuntimeError()
    def w32(self, a, v):
        if a & 3:
            self.fault = ("misaligned-store", self.pc, a); raise RuntimeError()
        self.stores.append((self.pc, a, v & M32)); self.stores = self.stores[-16:]
        if a == 0x40013804: self.uart_out.append(v & 0xFF); return
        if a == 0x40022004:  # FLASH_KEYR: KEY1 then KEY2 unlocks programming
            if v == 0x45670123 and self.fpec['kstage'] == 0:
                self.fpec['kstage'] = 1
            elif v == 0xCDEF89AB and self.fpec['kstage'] == 1:
                self.fpec['lock'] = False; self.fpec['kstage'] = 0
            else:
                self.fault = ("flash-keyr-seq", self.pc, v); raise RuntimeError()
            return
        if a == 0x40022024:  # FLASH_MODEKEYR: same sequence unlocks fast modes
            if v == 0x45670123 and self.fpec['mkstage'] == 0:
                self.fpec['mkstage'] = 1
            elif v == 0xCDEF89AB and self.fpec['mkstage'] == 1:
                self.fpec['flock'] = False; self.fpec['mkstage'] = 0
            else:
                self.fault = ("flash-modekeyr-seq", self.pc, v); raise RuntimeError()
            return
        if a == 0x40022014:  # FLASH_ADDR
            self.fpec['faddr'] = v & M32
            return
        if a == 0x40022010:  # FLASH_CTLR
            self.fpec['ctlr'] = v & M32
            ftpg = (v >> 16) & 1
            if ftpg and (v >> 19) & 1:           # BUFRST: clear the page buffer
                self.fpec['buf'] = [0xFFFFFFFF] * 16
            if ftpg and (v >> 18) & 1:           # BUFLOAD: latch the last word
                if self.fpec['lastw'] is None:
                    self.fault = ("flash-bufload-no-word", self.pc, v); raise RuntimeError()
                wa, wv = self.fpec['lastw']
                self.fpec['buf'][(wa & 63) >> 2] &= wv
                self.fpec['lastw'] = None
            if (v >> 6) & 1:                     # STRT
                if self.fpec['lock'] or self.fpec['flock']:
                    self.fault = ("flash-locked-op", self.pc, v); raise RuntimeError()
                pa = self._flash_pa(self.fpec['faddr'])
                if pa is None or (pa & 63):
                    self.fault = ("flash-op-addr", self.pc, self.fpec['faddr']); raise RuntimeError()
                if (v >> 17) & 1:                # FTER: fast page erase
                    for i in range(64): self.f[pa+i] = 0xFF
                elif ftpg:                       # FTPG: program the page buffer
                    for i, w in enumerate(self.fpec['buf']):
                        for b in range(4):
                            self.f[pa + 4*i + b] &= (w >> (8*b)) & 0xFF
                else:
                    self.fault = ("flash-strt-mode", self.pc, v); raise RuntimeError()
            return
        pa = self._flash_pa(a)
        if pa is not None:
            # word store into flash: only meaningful as the FTPG buffer-fill
            # step (the word is latched on the following BUFLOAD strobe)
            if (self.fpec['ctlr'] >> 16) & 1 and not self.fpec['flock']:
                self.fpec['lastw'] = (a, v & M32)
                return
            self.fault = ("flash-write-no-ftpg", self.pc, a); raise RuntimeError()
        for i in range(4): self.w8(a+i, (v >> (8*i)) & 0xFF)
    def w16(self, a, v):
        if a & 1:
            self.fault = ("misaligned-store16", self.pc, a); raise RuntimeError()
        if self._flash_pa(a) is not None:
            # standard halfword PG: corrupts on real CH32V006 silicon, so the
            # emulator refuses it outright
            self.fault = ("flash-halfword-pg-broken-on-v006", self.pc, a); raise RuntimeError()
        for i in range(2): self.w8(a+i, (v >> (8*i)) & 0xFF)

    def wr(self, rd, v):
        if rd: self.x[rd] = v & M32

    def step(self):
        pc = self.pc
        lo = self.r16(pc)
        self.trace.append(pc); self.trace = self.trace[-64:]
        if (lo & 3) != 3:
            self.step_c(lo); return
        inst = lo | (self.r16(pc+2) << 16)
        op = inst & 0x7F
        rd = (inst >> 7) & 0x1F; f3 = (inst >> 12) & 7
        rs1 = (inst >> 15) & 0x1F; rs2 = (inst >> 20) & 0x1F
        f7 = inst >> 25
        if op in (0x33,) and (rd > 15 or rs1 > 15 or rs2 > 15):
            self.fault = ("rv32e-reg", pc, inst); raise RuntimeError()
        X = self.x
        if op == 0x37: self.wr(rd, inst & 0xFFFFF000)                       # lui
        elif op == 0x17: self.wr(rd, (pc + (inst & 0xFFFFF000)) & M32)      # auipc
        elif op == 0x6F:                                                    # jal
            imm = sx(((inst>>31)<<20)|(((inst>>12)&0xFF)<<12)|(((inst>>20)&1)<<11)|(((inst>>21)&0x3FF)<<1), 21)
            self.wr(rd, pc+4); self.pc = (pc + imm) & M32; return
        elif op == 0x67:                                                    # jalr
            t = (X[rs1] + sx(inst>>20, 12)) & ~1 & M32
            self.wr(rd, pc+4); self.pc = t; return
        elif op == 0x63:                                                    # branches
            imm = sx(((inst>>31)<<12)|(((inst>>7)&1)<<11)|(((inst>>25)&0x3F)<<5)|(((inst>>8)&0xF)<<1), 13)
            a, b = X[rs1], X[rs2]; sa, sb = sx(a,32), sx(b,32)
            take = {0: a==b, 1: a!=b, 4: sa<sb, 5: sa>=sb, 6: a<b, 7: a>=b}[f3]
            self.pc = (pc + imm) & M32 if take else pc+4; return
        elif op == 0x03:                                                    # loads
            a = (X[rs1] + sx(inst>>20, 12)) & M32
            if f3 == 0: self.wr(rd, sx(self.r8(a),8) & M32)
            elif f3 == 1: self.wr(rd, sx(self.r16(a),16) & M32)
            elif f3 == 2: self.wr(rd, self.r32(a))
            elif f3 == 4: self.wr(rd, self.r8(a))
            elif f3 == 5: self.wr(rd, self.r16(a))
        elif op == 0x23:                                                    # stores
            imm = sx(((inst>>25)<<5) | ((inst>>7)&0x1F), 12)
            a = (X[rs1] + imm) & M32
            if f3 == 0: self.w8(a, X[rs2])
            elif f3 == 1: self.w16(a, X[rs2])
            elif f3 == 2: self.w32(a, X[rs2])
        elif op == 0x13:                                                    # alu-imm
            imm = sx(inst>>20, 12); a = X[rs1]
            if f3 == 0: self.wr(rd, a + imm)
            elif f3 == 2: self.wr(rd, 1 if sx(a,32) < imm else 0)
            elif f3 == 3: self.wr(rd, 1 if a < (imm & M32) else 0)
            elif f3 == 4: self.wr(rd, a ^ imm)
            elif f3 == 6: self.wr(rd, a | imm)
            elif f3 == 7: self.wr(rd, a & imm)
            elif f3 == 1: self.wr(rd, a << (rs2))
            elif f3 == 5:
                sh = rs2
                self.wr(rd, (sx(a,32) >> sh) & M32 if (f7 & 0x20) else a >> sh)
        elif op == 0x33:                                                    # alu-reg
            a, b = X[rs1], X[rs2]
            if f7 == 1:
                if f3 == 0: self.wr(rd, (a*b) & M32)                        # mul (Zmmul)
                else: self.fault = ("no-div", pc, inst); raise RuntimeError()
            elif f3 == 0: self.wr(rd, (a - b) if f7 == 0x20 else (a + b))
            elif f3 == 1: self.wr(rd, a << (b & 31))
            elif f3 == 2: self.wr(rd, 1 if sx(a,32) < sx(b,32) else 0)
            elif f3 == 3: self.wr(rd, 1 if a < b else 0)
            elif f3 == 4: self.wr(rd, a ^ b)
            elif f3 == 5: self.wr(rd, (sx(a,32) >> (b&31)) & M32 if (f7 & 0x20) else a >> (b&31))
            elif f3 == 6: self.wr(rd, a | b)
            elif f3 == 7: self.wr(rd, a & b)
        elif op == 0x73:                                                    # csr / mret
            if inst == 0x30200073:  # mret
                self.pc = self.csr.get(0x341, 0); return
            csr = inst >> 20
            old = self.csr.get(csr, 0)
            src = rs1 if f3 >= 5 else X[rs1]   # imm vs reg forms
            if f3 & 3 == 1: self.csr[csr] = src
            elif f3 & 3 == 2: self.csr[csr] = old | src
            elif f3 & 3 == 3: self.csr[csr] = old & ~src
            self.wr(rd, old)
        elif op == 0x0F: pass                                               # fence
        else:
            self.fault = ("illegal", pc, inst); raise RuntimeError()
        self.pc = pc + 4

    def step_c(self, i):
        pc = self.pc; X = self.x
        q = i & 3; f3 = (i >> 13) & 7
        r_ = lambda n: 8 + n
        if i == 0: self.fault = ("c.unimp", pc, i); raise RuntimeError()
        if q == 0:
            rdp = r_((i>>2)&7); rs1p = r_((i>>7)&7)
            if f3 == 0:  # c.addi4spn
                imm = (((i>>7)&0xF)<<6)|(((i>>11)&3)<<4)|(((i>>5)&1)<<3)|(((i>>6)&1)<<2)
                self.wr(rdp, X[2] + imm)
            elif f3 == 2:  # c.lw
                imm = (((i>>10)&7)<<3)|(((i>>6)&1)<<2)|(((i>>5)&1)<<6)
                self.wr(rdp, self.r32((X[rs1p]+imm) & M32))
            elif f3 == 6:  # c.sw
                imm = (((i>>10)&7)<<3)|(((i>>6)&1)<<2)|(((i>>5)&1)<<6)
                self.w32((X[rs1p]+imm) & M32, X[rdp])
            else: self.fault = ("c?", pc, i); raise RuntimeError()
        elif q == 1:
            if f3 == 0:  # c.addi
                rd = (i>>7)&0x1F; imm = sx((((i>>12)&1)<<5)|((i>>2)&0x1F), 6)
                self.wr(rd, X[rd] + imm)
            elif f3 == 1:  # c.jal
                imm = self.cj_imm(i); self.wr(1, pc+2); self.pc = (pc+imm) & M32; return
            elif f3 == 2:  # c.li
                rd = (i>>7)&0x1F; self.wr(rd, sx((((i>>12)&1)<<5)|((i>>2)&0x1F), 6) & M32)
            elif f3 == 3:
                rd = (i>>7)&0x1F
                if rd == 2:  # c.addi16sp
                    imm = sx((((i>>12)&1)<<9)|(((i>>3)&3)<<7)|(((i>>5)&1)<<6)|(((i>>2)&1)<<5)|(((i>>6)&1)<<4), 10)
                    self.wr(2, X[2] + imm)
                else:        # c.lui
                    self.wr(rd, sx((((i>>12)&1)<<17)|(((i>>2)&0x1F)<<12), 18) & M32)
            elif f3 == 4:
                rdp = r_((i>>7)&7); f2 = (i>>10)&3
                if f2 == 0: self.wr(rdp, X[rdp] >> ((((i>>12)&1)<<5)|((i>>2)&0x1F)))
                elif f2 == 1: self.wr(rdp, (sx(X[rdp],32) >> ((((i>>12)&1)<<5)|((i>>2)&0x1F))) & M32)
                elif f2 == 2: self.wr(rdp, X[rdp] & (sx((((i>>12)&1)<<5)|((i>>2)&0x1F),6) & M32))
                else:
                    rs2p = r_((i>>2)&7); f = ((i>>12)&1, (i>>5)&3)
                    if f == (0,0): self.wr(rdp, X[rdp]-X[rs2p])
                    elif f == (0,1): self.wr(rdp, X[rdp]^X[rs2p])
                    elif f == (0,2): self.wr(rdp, X[rdp]|X[rs2p])
                    elif f == (0,3): self.wr(rdp, X[rdp]&X[rs2p])
                    else: self.fault = ("c?", pc, i); raise RuntimeError()
            elif f3 == 5:  # c.j
                self.pc = (pc + self.cj_imm(i)) & M32; return
            elif f3 in (6,7):  # c.beqz / c.bnez
                rs1p = r_((i>>7)&7)
                imm = sx((((i>>12)&1)<<8)|(((i>>5)&3)<<6)|(((i>>2)&1)<<5)|(((i>>10)&3)<<3)|(((i>>3)&3)<<1), 9)
                t = (X[rs1p] == 0) if f3 == 6 else (X[rs1p] != 0)
                self.pc = (pc+imm) & M32 if t else pc+2; return
        elif q == 2:
            if f3 == 0:  # c.slli
                rd = (i>>7)&0x1F; self.wr(rd, X[rd] << ((((i>>12)&1)<<5)|((i>>2)&0x1F)))
            elif f3 == 2:  # c.lwsp
                rd = (i>>7)&0x1F
                imm = (((i>>12)&1)<<5)|(((i>>4)&7)<<2)|(((i>>2)&3)<<6)
                self.wr(rd, self.r32((X[2]+imm) & M32))
            elif f3 == 4:
                rs2 = (i>>2)&0x1F; rd = (i>>7)&0x1F
                if (i>>12)&1 == 0:
                    if rs2 == 0: self.pc = X[rd] & ~1; return            # c.jr
                    else: self.wr(rd, X[rs2])                            # c.mv
                else:
                    if rs2 == 0 and rd == 0: self.fault=("ebreak",pc,i); raise RuntimeError()
                    elif rs2 == 0: self.wr(1, pc+2); self.pc = X[rd] & ~1; return  # c.jalr
                    else: self.wr(rd, X[rd] + X[rs2])                    # c.add
            elif f3 == 6:  # c.swsp
                rs2 = (i>>2)&0x1F
                imm = (((i>>9)&0xF)<<2)|(((i>>7)&3)<<6)
                self.w32((X[2]+imm) & M32, X[rs2])
            else: self.fault = ("c?", pc, i); raise RuntimeError()
        self.pc = pc + 2

    def cj_imm(self, i):
        return sx((((i>>12)&1)<<11)|(((i>>11)&1)<<4)|(((i>>9)&3)<<8)|(((i>>8)&1)<<10)|
                  (((i>>7)&1)<<6)|(((i>>6)&1)<<7)|(((i>>3)&7)<<1)|(((i>>2)&1)<<5), 12)

def run(uart_input, max_steps=3_000_000, watch=None, flash=None, gpiod_in=0):
    if flash is None:
        flash = open('fiveforths.bin','rb').read()
    e = Emu(flash, uart_input.encode())
    e.gpiod_in = gpiod_in
    try:
        for n in range(max_steps):
            if watch: watch(e, n)
            e.step()
    except RuntimeError:
        pass
    return e

if __name__ == '__main__':
    e = run("d\n")
    print("FAULT:", e.fault)
    print("OUT:", bytes(e.uart_out))
    print("PC trace (last 40):", [hex(p) for p in e.trace[-40:]])
    print("regs:", {f"x{i}": hex(v) for i, v in enumerate(e.x)})
    print("last stores:", [(hex(p), hex(a), hex(v)) for p, a, v in e.stores])
