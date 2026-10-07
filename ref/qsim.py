#!/usr/bin/env python3
"""
qsim.py : model referensi emulator quantum state-vector untuk Basys 3.

  - model float (NumPy)                         -> "kebenaran" matematis
  - model fixed-point bit-accurate              -> harus SAMA PERSIS dengan hardware VHDL
  - assembler teks -> instruksi 16-bit          -> dipakai tb dan host/send_program.py
  - generator file sim/*.mem                    -> prog_*.mem, golden_*.mem, gate_vectors.mem

Konvensi (harus sama dengan src/*.vhd):
  qubit 0 = LSB indeks state
  amplitudo        : Q1.15 int16  (1.0 ~ 0x7FFF)
  koefisien gerbang: Q2.14 int16  (1.0 = 0x4000)
  hasil kali dibulatkan (round-half-up) lalu digeser 14 bit, saturasi ke int16
  instruksi 16-bit : [opcode:4][target:4][control:4][param:4], control=0xF -> tanpa kontrol
  RY/RZ            : theta = param * pi/8  (param 0..15), koefisien memakai cos/sin(param*pi/16)

Pemakaian:
  python qsim.py gen [--n 4] [--out ../sim]   buat semua file .mem
  python qsim.py list                         daftar program demo
  python qsim.py asm file.asm                 assemble ke hex (stdout)
  python qsim.py check                        uji konsistensi (float vs fixed, tabel trig vs VHDL)
  python qsim.py trig                         cetak tabel cos/sin Q2.14 untuk gate_engine.vhd
"""
import argparse
import math
import os
import random
import re
import sys
from collections import namedtuple

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))

OPCODES = {"NOP": 0, "H": 1, "X": 2, "Y": 3, "Z": 4, "S": 5, "T": 6,
           "RY": 7, "RZ": 8, "MEASURE": 9, "RESET": 0xF}
NO_CTRL = 0xF
SINGLE = {"H", "X", "Y", "Z", "S", "T"}
ROT = {"RY", "RZ"}

Instr = namedtuple("Instr", "op tgt ctl par")


# ------------------------------------------------------------ fixed-point util
def q14(x):
    return int(np.clip(round(x * 16384), -32768, 32767))


def sat16(v):
    return max(-32768, min(32767, v))


def rnd_shift(acc):
    """(acc + 8192) >>> 14 lalu saturasi int16. Python >> pada int negatif = aritmetik."""
    return sat16((acc + (1 << 13)) >> 14)


def trig_tables():
    cos_t = [q14(math.cos(k * math.pi / 16)) for k in range(16)]
    sin_t = [q14(math.sin(k * math.pi / 16)) for k in range(16)]
    return cos_t, sin_t


# ----------------------------------------------------------------- gate matrix
def gate_matrix(op, par=0):
    s2 = 1 / math.sqrt(2)
    if op == "H":
        return np.array([[s2, s2], [s2, -s2]], dtype=complex)
    if op == "X":
        return np.array([[0, 1], [1, 0]], dtype=complex)
    if op == "Y":
        return np.array([[0, -1j], [1j, 0]], dtype=complex)
    if op == "Z":
        return np.array([[1, 0], [0, -1]], dtype=complex)
    if op == "S":
        return np.array([[1, 0], [0, 1j]], dtype=complex)
    if op == "T":
        return np.array([[1, 0], [0, np.exp(1j * np.pi / 4)]], dtype=complex)
    if op == "RY":
        c, s = math.cos(par * math.pi / 16), math.sin(par * math.pi / 16)
        return np.array([[c, -s], [s, c]], dtype=complex)
    if op == "RZ":
        c, s = math.cos(par * math.pi / 16), math.sin(par * math.pi / 16)
        return np.array([[c - 1j * s, 0], [0, c + 1j * s]], dtype=complex)
    raise ValueError(f"bukan gerbang: {op}")


def coef_fx(op, par=0):
    """[(g00r,g00i),(g01r,g01i),(g10r,g10i),(g11r,g11i)] dalam Q2.14."""
    u = gate_matrix(op, par)
    return [(q14(u[r, c].real), q14(u[r, c].imag)) for r in range(2) for c in range(2)]


# ---------------------------------------------------------------- float model
def apply_float(state, op, tgt, ctl, par, n):
    u = gate_matrix(op, par)
    new = state.copy()
    for i0 in range(2 ** n):
        if (i0 >> tgt) & 1:
            continue
        if ctl != NO_CTRL and not (i0 >> ctl) & 1:
            continue
        i1 = i0 | (1 << tgt)
        a, b = state[i0], state[i1]
        new[i0] = u[0, 0] * a + u[0, 1] * b
        new[i1] = u[1, 0] * a + u[1, 1] * b
    return new


def run_float(n, prog):
    s = np.zeros(2 ** n, dtype=complex)
    s[0] = 1
    for ins in prog:
        if ins.op == "RESET":
            s[:] = 0
            s[0] = 1
        elif ins.op in SINGLE | ROT:
            s = apply_float(s, ins.op, ins.tgt, ins.ctl, ins.par, n)
    return s


# ----------------------------------------------------------- fixed-point model
def butterfly_fx(coef, ar, ai, br, bi):
    (g00r, g00i), (g01r, g01i), (g10r, g10i), (g11r, g11i) = coef
    a2r = rnd_shift(g00r * ar - g00i * ai + g01r * br - g01i * bi)
    a2i = rnd_shift(g00r * ai + g00i * ar + g01r * bi + g01i * br)
    b2r = rnd_shift(g10r * ar - g10i * ai + g11r * br - g11i * bi)
    b2i = rnd_shift(g10r * ai + g10i * ar + g11r * bi + g11i * br)
    return a2r, a2i, b2r, b2i


def run_fx(n, prog):
    re = [0] * (2 ** n)
    im = [0] * (2 ** n)
    re[0] = 0x7FFF
    for ins in prog:
        if ins.op == "RESET":
            re = [0] * (2 ** n)
            im = [0] * (2 ** n)
            re[0] = 0x7FFF
        elif ins.op in SINGLE | ROT:
            coef = coef_fx(ins.op, ins.par)
            nre, nim = re[:], im[:]
            for i0 in range(2 ** n):
                if (i0 >> ins.tgt) & 1:
                    continue
                if ins.ctl != NO_CTRL and not (i0 >> ins.ctl) & 1:
                    continue
                i1 = i0 | (1 << ins.tgt)
                nre[i0], nim[i0], nre[i1], nim[i1] = butterfly_fx(
                    coef, re[i0], im[i0], re[i1], im[i1])
            re, im = nre, nim
    return re, im


def fx_to_complex(re, im):
    return (np.array(re) + 1j * np.array(im)) / 32768.0


def fidelity(a, b):
    a = a / np.linalg.norm(a)
    b = b / np.linalg.norm(b)
    return float(abs(np.vdot(a, b)) ** 2)


# ------------------------------------------------------------------- assembler
def assemble(text):
    prog = []
    for ln, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#")[0].split(";")[0].strip()
        if not line:
            continue
        tok = line.replace(",", " ").split()
        m = tok[0].upper()
        try:
            a = [int(t, 0) for t in tok[1:]]
        except ValueError:
            raise ValueError(f"baris {ln}: operand harus angka: {raw!r}")

        def need(k):
            if len(a) != k:
                raise ValueError(f"baris {ln}: {m} butuh {k} operand: {raw!r}")

        if m in ("NOP", "RESET", "MEASURE"):
            need(0)
            ins = Instr(m, 0, 0, 0)
        elif m in SINGLE:
            need(1)
            ins = Instr(m, a[0], NO_CTRL, 0)
        elif m in ROT:
            need(2)
            ins = Instr(m, a[0], NO_CTRL, a[1])
        elif m in ("CNOT", "CX"):
            need(2)
            ins = Instr("X", a[1], a[0], 0)
        elif m.startswith("C") and m[1:] in SINGLE:
            need(2)
            ins = Instr(m[1:], a[1], a[0], 0)
        elif m.startswith("C") and m[1:] in ROT:
            need(3)
            ins = Instr(m[1:], a[1], a[0], a[2])
        else:
            raise ValueError(f"baris {ln}: mnemonic tidak dikenal: {raw!r}")

        if ins.op in SINGLE | ROT:
            if not (0 <= ins.tgt <= 14) or not (ins.ctl == NO_CTRL or 0 <= ins.ctl <= 14):
                raise ValueError(f"baris {ln}: indeks qubit di luar 0..14")
            if ins.ctl == ins.tgt:
                raise ValueError(f"baris {ln}: control sama dengan target")
            if not 0 <= ins.par <= 15:
                raise ValueError(f"baris {ln}: param harus 0..15")
        prog.append(ins)
    return prog


def encode(ins):
    return (OPCODES[ins.op] << 12) | (ins.tgt << 8) | (ins.ctl << 4) | ins.par


def max_qubit(prog):
    q = -1
    for i in prog:
        if i.op in SINGLE | ROT:
            q = max(q, i.tgt, i.ctl if i.ctl != NO_CTRL else -1)
    return q


# ----------------------------------------------------------------- program demo
PROGRAMS = {
    "bell": """
        RESET
        H 0
        CNOT 0 1
    """,
    "ghz4": """
        RESET
        H 0
        CNOT 0 1
        CNOT 1 2
        CNOT 2 3
    """,
    "grover2": """            # cari |11> pada qubit 0,1 (1 iterasi cukup)
        RESET
        H 0
        H 1
        CZ 0 1               # oracle
        H 0
        H 1
        X 0
        X 1
        CZ 0 1               # difusi
        X 0
        X 1
        H 0
        H 1
    """,
    "dj3_balanced": """      # Deutsch-Jozsa, f(x)=x0 (balanced), ancilla = qubit 2
        RESET
        X 2
        H 0
        H 1
        H 2
        CNOT 0 2
        H 0
        H 1
    """,
    "dj3_constant": """      # Deutsch-Jozsa, f(x)=0 (constant) -> input harus kembali |00>
        RESET
        X 2
        H 0
        H 1
        H 2
        H 0
        H 1
    """,
    "qft3": """
        RESET
        X 0
        H 2
        CS 1 2
        CT 0 2
        H 1
        CS 0 1
        H 0
        CNOT 0 2
        CNOT 2 0
        CNOT 0 2
    """,
    "rabi_04": "RESET\nRY 0 4\n",                    # theta = pi/2 -> P(1) = 0.5
    "rabi_08": "RESET\nRY 0 8\n",                    # theta = pi   -> P(1) = 1
    "rz_04": "RESET\nH 0\nRZ 0 4\nH 0\n",            # interferensi fase -> P(1) = 0.5
    "cry": "RESET\nX 0\nCRY 0 1 8\n",                # RY(pi) pada qubit 1 hanya jika qubit 0 = 1
}


# -------------------------------------------------------------------- generator
def hex16(v):
    return f"{v & 0xFFFF:04X}"


def gen(outdir, n):
    os.makedirs(outdir, exist_ok=True)
    print(f"{'program':14s} {'instr':>5s} {'max_err':>9s} {'fidelity':>9s}  state dominan")
    for name, src in PROGRAMS.items():
        prog = assemble(src)
        if max_qubit(prog) >= n:
            print(f"{name:14s} dilewati (butuh > {n} qubit)")
            continue
        re, im = run_fx(n, prog)
        ref = run_float(n, prog)
        fx = fx_to_complex(re, im)
        top = int(np.argmax(np.abs(fx)))
        print(f"{name:14s} {len(prog):5d} {np.max(np.abs(ref - fx)):9.2e} "
              f"{fidelity(ref, fx):9.6f}  |{top:0{n}b}> p={abs(fx[top]) ** 2:.3f}")
        with open(os.path.join(outdir, f"prog_{name}.mem"), "w", newline="\n") as f:
            f.writelines(f"{encode(i):04X}\n" for i in prog)
        with open(os.path.join(outdir, f"golden_{name}.mem"), "w", newline="\n") as f:
            f.writelines(f"{hex16(r)}{hex16(i)}\n" for r, i in zip(re, im))

    # vektor uji untuk tb_gate_engine: op par a b exp_a exp_b
    rng = random.Random(1234)
    combos = [(g, 0) for g in ("H", "X", "Y", "Z", "S", "T")] + \
             [(g, k) for g in ("RY", "RZ") for k in range(16)]
    corners = [(0x7FFF, 0, 0, 0), (0, 0, 0x7FFF, 0), (0x8000, 0x8000, 0x8000, 0x8000),
               (0x7FFF, 0x7FFF, 0x7FFF, 0x7FFF), (0, 0, 0, 0)]
    s16 = lambda v: v - 0x10000 if v & 0x8000 else v
    with open(os.path.join(outdir, "gate_vectors.mem"), "w", newline="\n") as f:
        for op, par in combos:
            vecs = corners + [tuple(rng.randrange(0x10000) for _ in range(4)) for _ in range(8)]
            for ar, ai, br, bi in vecs:
                a2r, a2i, b2r, b2i = butterfly_fx(coef_fx(op, par), s16(ar), s16(ai), s16(br), s16(bi))
                f.write(f"{OPCODES[op]:X} {par:X} {hex16(ar)}{hex16(ai)} {hex16(br)}{hex16(bi)} "
                        f"{hex16(a2r)}{hex16(a2i)} {hex16(b2r)}{hex16(b2i)}\n")
    print(f"\nfile .mem ditulis ke {os.path.abspath(outdir)}")


def check():
    ok = True
    for name, src in PROGRAMS.items():
        prog = assemble(src)
        n = max(max_qubit(prog) + 1, 2)
        f = fidelity(run_float(n, prog), fx_to_complex(*run_fx(n, prog)))
        good = f > 0.999
        ok &= good
        print(f"{'OK  ' if good else 'FAIL'} {name:14s} fidelity={f:.6f}")

    vhd = os.path.join(HERE, "..", "src", "gate_engine.vhd")
    if os.path.exists(vhd):
        txt = open(vhd).read()
        cos_t, sin_t = trig_tables()
        for tag, tab in (("COS_T", cos_t), ("SIN_T", sin_t)):
            m = re.search(tag + r"\s*:\s*int_arr\s*:=\s*\(([^)]*)\)", txt)
            vals = [int(x) for x in m.group(1).replace("\n", " ").split(",")] if m else None
            good = vals == tab
            ok &= good
            print(f"{'OK  ' if good else 'FAIL'} tabel {tag} di gate_engine.vhd")
    sys.exit(0 if ok else 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("cmd", nargs="?", default="gen", choices=["gen", "list", "asm", "check", "trig"])
    ap.add_argument("file", nargs="?")
    ap.add_argument("--n", type=int, default=4, help="jumlah qubit (default 4)")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "sim"))
    a = ap.parse_args()

    if a.cmd == "gen":
        gen(a.out, a.n)
    elif a.cmd == "list":
        for k in PROGRAMS:
            print(k)
    elif a.cmd == "asm":
        src = open(a.file).read() if a.file else sys.stdin.read()
        for i in assemble(src):
            print(f"{encode(i):04X}")
    elif a.cmd == "check":
        check()
    elif a.cmd == "trig":
        c, s = trig_tables()
        print("constant COS_T : int_arr := (" + ", ".join(map(str, c)) + ");")
        print("constant SIN_T : int_arr := (" + ", ".join(map(str, s)) + ");")


if __name__ == "__main__":
    main()
