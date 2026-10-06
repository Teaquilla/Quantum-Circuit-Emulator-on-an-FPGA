#!/usr/bin/env python3
"""
send_program.py : kirim program sirkuit kuantum ke Basys 3 lewat UART (8N1).

Tiap instruksi = 2 byte (byte tinggi dulu). Hasil dilihat di LED board (lihat README).

Contoh:
  python send_program.py --list
  python send_program.py COM5 --demo bell
  python send_program.py /dev/ttyUSB1 --asm ../ref/my_circuit.asm --delay 0.01
  python send_program.py COM5 --mem ../sim/prog_ghz4.mem
  python send_program.py --demo grover2 --dry-run          # tanpa board, hanya tampilkan hex

Butuh: pip install pyserial
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ref"))
import qsim  # noqa: E402


def load_words(args):
    if args.demo:
        if args.demo not in qsim.PROGRAMS:
            sys.exit(f"demo '{args.demo}' tidak ada. Pilihan: {', '.join(qsim.PROGRAMS)}")
        return [qsim.encode(i) for i in qsim.assemble(qsim.PROGRAMS[args.demo])]
    if args.asm:
        with open(args.asm) as f:
            return [qsim.encode(i) for i in qsim.assemble(f.read())]
    if args.mem:
        with open(args.mem) as f:
            return [int(ln.strip(), 16) for ln in f if ln.strip()]
    sys.exit("pilih salah satu: --demo NAMA | --asm FILE | --mem FILE")


def main():
    ap = argparse.ArgumentParser(description="Kirim program kuantum ke Basys 3")
    ap.add_argument("port", nargs="?", help="mis. COM5 atau /dev/ttyUSB1")
    ap.add_argument("--demo", help="nama program bawaan (lihat --list)")
    ap.add_argument("--asm", help="file assembly teks")
    ap.add_argument("--mem", help="file .mem berisi hex 16-bit per baris")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--delay", type=float, default=0.005,
                    help="jeda antar instruksi (detik), default 0.005")
    ap.add_argument("--dry-run", action="store_true", help="hanya cetak, tidak membuka port")
    ap.add_argument("--list", action="store_true", help="daftar demo dan port serial")
    args = ap.parse_args()

    if args.list:
        print("demo:", ", ".join(qsim.PROGRAMS))
        try:
            from serial.tools import list_ports
            for p in list_ports.comports():
                print("port:", p.device, "-", p.description)
        except ImportError:
            print("(pyserial belum terpasang: pip install pyserial)")
        return

    words = load_words(args)
    print(f"{len(words)} instruksi:", " ".join(f"{w:04X}" for w in words))
    if args.dry_run:
        return
    if not args.port:
        sys.exit("sebutkan port serial (atau pakai --dry-run)")

    try:
        import serial
    except ImportError:
        sys.exit("pyserial belum terpasang: pip install pyserial")

    with serial.Serial(args.port, args.baud, bytesize=8, parity="N", stopbits=1, timeout=1) as ser:
        for w in words:
            ser.write(bytes([(w >> 8) & 0xFF, w & 0xFF]))
            ser.flush()
            time.sleep(args.delay)
    print("terkirim. Lihat LED pada board.")


if __name__ == "__main__":
    main()
