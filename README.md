# Emulator Quantum Circuit di FPGA

Akselerator hardware untuk mengemulasikan **sirkuit kuantum kecil (state-vector)** pada FPGA Artix-7 di board **Basys 3**
(`xc7a35tcpg236-1`). Ditulis dalam **VHDL** untuk **Vivado**, diverifikasi bit-per-bit terhadap model referensi Python.
Default **4 qubit**, jumlah qubit bisa diubah lewat generic `N_QUBITS`.

> **Catatan untuk laporan:** ini *emulator/simulator* state-vector di hardware, **bukan** komputer kuantum fisik.
> Kontribusi nyatanya: datapath fixed-point, FSM kontrol, verifikasi bit-accurate, serta analisis error numerik dan resource.

## Status

| Tahap | Status |
|---|---|
| Model referensi Python (float + fixed-point bit-accurate) | ✅ fidelity > 0,999 untuk semua demo |
| Simulasi behavioral xsim (Vivado 2026.1) | ✅ `tb_gate_engine` (494 vektor), `tb_qcore` (10/10 program), `tb_qemu_top` (4 kasus) |
| Sintesis 4 qubit | ✅ timing 100 MHz terpenuhi (lihat [Hasil](#hasil-sintesis-dan-implementasi)) |
| Implementasi + bitstream | 🔄 sampai tahap Generate Bitstream; angka final diisi di bagian Hasil |
| Uji di board (UART → LED) | ⏳ menunggu board dipinjam |
| CI GitHub Actions | 🔄 workflow diperluas (model Python + simulasi 3 testbench dengan GHDL); menunggu run pertama |

---

## 1. Cara kerja

n qubit = 2ⁿ amplitudo kompleks. Gerbang 1-qubit pada qubit target `t` adalah perkalian matriks 2×2 pada setiap pasangan
amplitudo `(i0, i1)` yang indeksnya hanya berbeda di bit `t`:

```
[a']   [g00 g01] [a]        a = state[i0]   (bit t = 0)
[b'] = [g10 g11] [b]        b = state[i1]   (bit t = 1)
```

- **Gerbang terkontrol** (CNOT, CZ, CS, CRY, ...) = gerbang biasa + field *control*; pasangan dilewati bila bit control pada `i0` bernilai 0.
  Tidak ada datapath khusus untuk CNOT.
- Satu unit butterfly dipakai berulang untuk semua pasangan (2ⁿ⁻¹ pasangan per gerbang).
- Qubit 0 = LSB indeks state.

```
 PC ──UART 115200 8N1──► uart_rx ──► perakit 2 byte ──► ┌─────────────────────────── qcore ───────────────────────────┐
 (host/send_program.py)                (qemu_top)       │  qstate_ctrl ──alamat/WE──► qstate_ram (2^N x 32 bit)       │
                                                        │      │  ▲                        │ dout A/B                │
                                                        │      ▼  │ valid_out/hasil        ▼                         │
                                                        │   gate_engine (butterfly 2x2 kompleks, 4 tahap) ◄───────┘   │
                                                        └──────────────────────────────┬───────────────────────────────┘
                                          scan state (re²+im²) ◄───── rd_addr/rd_data ──┘ ──► LED[15:0]
```

Siklus per pasangan ≈ 7 clock (`ISSUE` → `CAPTURE` → 4 clock `WAIT_ENG` → `NEXT`):
4 qubit ≈ 60 clock (~0,6 µs @ 100 MHz) per gerbang, 10 qubit ≈ 3.600 clock (~36 µs).

## 2. Struktur repo

```
src/      gate_engine.vhd  qstate_ram.vhd  qstate_ctrl.vhd  qcore.vhd  uart_rx.vhd  qemu_top.vhd
sim/      tb_gate_engine.vhd  tb_qcore.vhd  tb_qemu_top.vhd  + prog_*.mem / golden_*.mem / gate_vectors.mem
ref/      qsim.py           model referensi float + fixed-point bit-accurate + assembler + generator .mem
host/     send_program.py   kirim program ke board lewat UART
constr/   basys3.xdc
scripts/  create_project.tcl  sim_ghdl.sh
```

| File | Peran |
|---|---|
| `gate_engine.vhd` | Butterfly 2×2 kompleks, pipeline 4 tahap (operand → 16 perkalian/DSP → jumlah 34 bit → round + saturasi), tabel koefisien gerbang. |
| `qstate_ram.vhd` | Memori state vector 2ᴺ × 32 bit `{re, im}`, true dual-port read-first (pola shared variable Xilinx + `ram_style = block`). **Harus bertipe VHDL (bukan 2008) di Vivado.** |
| `qstate_ctrl.vhd` | FSM: dekode instruksi, iterasi pasangan indeks, gerbang terkontrol, `RESET`; operand tidak valid → NOP. |
| `qcore.vhd` | Gabungan RAM + engine + ctrl, tanpa pin/UART (dipakai testbench). |
| `uart_rx.vhd` | Penerima UART 8N1 (generic `CLK_HZ`, `BAUD`). |
| `qemu_top.vhd` | Top Basys 3: UART → instruksi 16-bit → `qcore` → scan state → LED. RESET otomatis saat power-up / `btnC`. |
| `tb_gate_engine.vhd` | Engine vs `gate_vectors.mem` (494 vektor, semua gerbang, RY/RZ param 0..15, saturasi). |
| `tb_qcore.vhd` | 10 program vs `golden_*.mem`, seluruh state vector dibandingkan bit per bit. |
| `tb_qemu_top.vhd` | Uji ujung-ke-ujung: byte UART → LED (boot, Bell, X, superposisi 4 qubit). Tanpa file `.mem`. |
| `ref/qsim.py` | Model float (NumPy), model fixed-point identik dengan hardware, assembler, generator `.mem`. |
| `host/send_program.py` | Kirim program (`--demo`, `--asm`, `--mem`) ke board. |

## 3. Format angka dan instruksi

| Besaran | Format | Catatan |
|---|---|---|
| Amplitudo (re, im) | **Q1.15**, int16 | 1,0 ≈ `0x7FFF` |
| Koefisien gerbang | **Q2.14**, int16 | 1,0 = `0x4000` (Q1.15 tidak bisa menyimpan 1,0) |
| Akumulator | 34 bit | 4 suku × (16×16 bit), dijumlah penuh sebelum dipotong |
| Pembulatan | `(x + 8192) >>> 14` | round-half-up, bukan truncation (truncation membuat norma state menyusut) |
| Saturasi | ke int16 | |
| Entri RAM | 32 bit | `{re, im}` |

Instruksi 16-bit: `[opcode:4][target:4][control:4][param:4]`, `control = F` berarti tanpa kontrol.

| Opcode | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | F |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Mnemonic | NOP | H | X | Y | Z | S | T | RY | RZ | MEASURE* | RESET |

\* `MEASURE` dicadangkan (saat ini sama dengan NOP). `RY`/`RZ`: θ = `param` × π/8, `param` 0..15.

Sintaks assembly (komentar dengan `#`):

```
RESET             # state kembali ke |0...0>
H 0               # Hadamard pada qubit 0
CNOT 0 1          # control=0, target=1   (alias: CX)
CZ 0 1            # gerbang terkontrol: C + {H X Y Z S T}
CS 1 2            # controlled-S
RY 0 4            # rotasi, param 0..15
CRY 0 1 8         # controlled-RY: control target param
```

## 4. Quick start

```bash
git clone https://github.com/Teaquilla/Emulator-Quantum-Circuit-in-FPGA.git
cd Emulator-Quantum-Circuit-in-FPGA
pip install numpy pyserial
```

**a. Model dan file simulasi** (hasilnya ada di `sim/`, sudah ikut di repo)
```bash
python ref/qsim.py gen      # buat sim/*.mem
python ref/qsim.py check    # float vs fixed-point + cek tabel trig di gate_engine.vhd
python ref/qsim.py list     # daftar program demo
```

**b. Simulasi di Vivado**
```bash
vivado -mode batch -source scripts/create_project.tcl
```
Lalu ganti top simulasi dan *Run Behavioral Simulation*; di Tcl Console harus muncul `PASS` / `ALL TESTS PASSED`:
```tcl
set_property top tb_gate_engine [get_filesets sim_1]
set_property top tb_qcore       [get_filesets sim_1]
set_property top tb_qemu_top    [get_filesets sim_1]
```

**c. Simulasi dengan GHDL (tanpa Vivado)**
```bash
cd scripts && ./sim_ghdl.sh tb_qcore      # atau tb_gate_engine / tb_qemu_top
```
Flag `-frelaxed` dipakai karena `qstate_ram` memakai shared variable bertipe biasa.

**d. Bitstream dan board**
*Run Synthesis → Run Implementation → Generate Bitstream → Open Hardware Manager → Program Device.*
Bitstream tidak disimpan di repo; unduh `qemu_top.bit` dari halaman **Releases** bila tersedia.

**e. Kirim program**
```bash
python host/send_program.py --list                     # demo + port serial
python host/send_program.py COM5 --demo bell           # Linux: /dev/ttyUSB1
python host/send_program.py COM5 --asm sirkuitku.asm
python host/send_program.py --demo grover2 --dry-run   # tanpa board, hanya cetak hex
```

## 5. Membaca hasil di LED

Setelah tiap instruksi, `qemu_top` membaca semua amplitudo, menghitung p = re² + im², lalu **LED[i] menyala bila p(state i) ≥ ambang**.
Ambang diatur **`sw[2:0]` = k**: 0,25 / 2ᵏ (k=0: 0,25 · k=1: 0,125 · k=2: 0,0625 · … · k=7: 1/512).
Hanya 16 state pertama yang ditampilkan. `btnC` = reset (hanya LED0 menyala). Indeks LED = nilai biner state, qubit 0 sebagai bit terendah.

| Demo | Sirkuit | LED yang menyala (sw = 000) |
|---|---|---|
| `bell` | H, CNOT | 0 dan 3 (p = 0,5) |
| `ghz4` | H + rantai CNOT | 0 dan 15 |
| `grover2` | Grover 2 qubit, target \|11⟩ | 3 (p = 1) |
| `dj3_balanced` | Deutsch-Jozsa, f(x)=x0 | 1 dan 5 (input ≠ 00 → balanced) |
| `dj3_constant` | Deutsch-Jozsa, f(x)=0 | 0 dan 4 (input = 00 → constant) |
| `qft3` | QFT 3 qubit pada \|001⟩ | p = 0,125 per state 0..7 → naikkan ke `sw = 001` atau `010` |
| `rabi_04` | RY(π/2) | 0 dan 1 (p = 0,5) |
| `rabi_08` | RY(π) | 1 (p = 1) |
| `rz_04` | H, RZ(π/2), H | 0 dan 1 (p = 0,5) |
| `cry` | X 0, CRY(π) 0→1 | 3 (p = 1) |

Osilasi Rabi: kirim `RESET` lalu `RY 0 k`, k = 0..15; probabilitas |1⟩ = sin²(kπ/16).

## 6. CI (GitHub Actions)

Workflow **FPGA VHDL CI Pipeline** (`.github/workflows/vhdl_ci.yml`) berjalan pada setiap push dan pull request ke `main`, atau manual lewat *Run workflow*. Ada dua job:

| Job | Isi |
|---|---|
| **Python Reference Model** | `python ref/qsim.py check` (float vs fixed-point, tabel cos/sin di `gate_engine.vhd`); `qsim.py gen` lalu `git diff` untuk memastikan `sim/*.mem` yang di-commit sinkron dengan model; uji `host/send_program.py --dry-run`. |
| **VHDL Analyze & Simulate (GHDL)** | Menganalisis semua file VHDL (`--std=08 -frelaxed`) lalu menjalankan `tb_gate_engine`, `tb_qcore`, dan `tb_qemu_top`. Job gagal bila ada `FAIL`/error atau kalimat `PASS` / `ALL TESTS PASSED` tidak muncul. |

Catatan: versi awal workflow memakai `find ... -exec ghdl -s {} \;`. Perintah itu hanya memeriksa sintaks per file dan status keluarnya
diabaikan oleh `find`, sehingga CI bisa hijau walaupun ada error. Versi sekarang tidak punya masalah itu.
Bila `.mem` tidak sinkron, jalankan `python ref/qsim.py gen` lalu commit hasilnya.

## Hasil sintesis dan implementasi

Target: Basys 3, 100 MHz, `N_QUBITS = 4`.

| Tahap | LUT | FF | BRAM | DSP | WNS (ns) | Catatan |
|---|---|---|---|---|---|---|
| Sintesis #1 (RAM terinferensi sebagai flip-flop) | 1.210 | 730 | 0 | 20 | +4,159 | `qstate_ram` = 512 FF; ctrl 740 LUT |
| Sintesis #2 (RAM pola Xilinx TDP) | _isi_ | _isi_ | _isi_ | _isi_ | _isi_ | |
| Implementasi (pasca-route) | _isi_ | _isi_ | _isi_ | _isi_ | _isi_ | WNS final |

DSP: 18 di `gate_engine` + 2 di `qemu_top` (kuadrat amplitudo untuk scan LED).
Untuk analisis skalabilitas, ulangi sintesis dengan `N_QUBITS` = 6, 8, 10 dan catat LUT/FF/BRAM/DSP serta WNS. Salinan laporan boleh disimpan di folder `reports/`.

## 7. Checklist uji di board

1. Program `qemu_top.bit` → hanya **LED0** menyala (core menjalankan `RESET` sendiri).
2. `--demo bell` → LED0 + LED3. Tekan `btnC` untuk reset.
3. `ghz4` (LED0, LED15) → `grover2` (LED3) → `rabi_08` (LED1) → `cry` (LED3).
4. Foto/video LED tiap demo untuk laporan. Variasikan `sw[2:0]`.

## 8. Troubleshooting

| Gejala | Penyebab / solusi |
|---|---|
| Sintesis: `array index -1 out of range` di `qstate_ctrl.vhd` | Sudah diperbaiki (guard `j > 0` di `insert_zero`). Pastikan memakai versi terbaru. |
| `u_ram` jadi 512 FF, tidak ada BRAM | Pakai `qstate_ram.vhd` versi shared variable dan set tipe file-nya ke **VHDL** (bukan 2008). |
| xsim/GHDL: shared variable harus protected | xsim: file bertipe VHDL; GHDL: tambahkan `-frelaxed`. |
| Testbench: file `.mem` tidak ditemukan | Set generic `SIM_DIR` ke path absolut folder `sim/` (lihat komentar di `create_project.tcl`). |
| LED tidak berubah saat mengirim program | Cek nomor COM, port tidak dipakai program lain, pin `RsRx` = B18, tekan `btnC` lalu kirim ulang. |
| `python`: modul `serial` tidak ada | `pip install pyserial`. |

## 9. Batasan dan rencana

- Belum ada: `MEASURE` (sampling LFSR + histogram), UART TX (kirim state ke PC), CORDIC (rotasi sekarang memakai tabel 16 sudut).
- Hasil hanya lewat LED; presisi 16 bit sehingga error akumulasi tumbuh seiring banyaknya gerbang.
- Pin di `basys3.xdc` diambil dari master XDC Digilent; cocokkan dengan file resmi.
- `tb_qemu_top` memakai baud yang dipercepat (10 clock/bit); pembagi 868 clock/bit pada 115200 baud baru teruji di board.

Rencana: (1) `MEASURE` dengan LFSR 32-bit + histogram, (2) `uart_tx` untuk plot dan perbandingan dengan NumPy, (3) tabel sudut lebih halus atau CORDIC,
(4) pipeline penuh antar-pasangan (≈ 1 pasangan/clock), (5) model Bloch/Rabi dengan T1/T2 sebagai tambahan bertema *quantum control*.
