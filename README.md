# quantum_fpga — Emulator Quantum Circuit (State-Vector) di Basys 3

Akselerator hardware untuk mengemulasikan sirkuit kuantum kecil (default **4 qubit**, bisa diubah lewat generic `N_QUBITS`)
pada FPGA Artix-7 (Basys 3, `xc7a35tcpg236-1`), ditulis dalam **VHDL-2008** untuk **Vivado**.

> **Catatan jujur untuk laporan:** ini *emulator/simulator* state-vector, **bukan** komputer kuantum fisik.
> Kontribusi nyatanya: datapath fixed-point, FSM kontrol, verifikasi bit-accurate terhadap model Python,
> serta analisis error numerik dan penggunaan resource.

---

## 1. Cara kerja singkat

n qubit direpresentasikan sebagai 2ⁿ amplitudo kompleks. Gerbang 1-qubit pada qubit target `t` adalah perkalian matriks 2×2
pada setiap pasangan amplitudo `(i0, i1)` yang indeksnya hanya berbeda di bit `t`:

```
[a']   [g00 g01] [a]        a = state[i0]   (bit t = 0)
[b'] = [g10 g11] [b]        b = state[i1]   (bit t = 1)
```

- **Gerbang terkontrol** (CNOT, CZ, CS, CRY, ...) = gerbang biasa + field *control*; pasangan dilewati bila bit control pada `i0` bernilai 0.
  Jadi tidak ada datapath khusus untuk CNOT.
- Satu unit butterfly dipakai berulang untuk semua pasangan (2ⁿ⁻¹ pasangan per gerbang).
- Qubit 0 = LSB dari indeks state.

### Diagram blok

```
 PC ──UART 115200 8N1──► uart_rx ──► perakit 2 byte ──► ┌────────────────────────── qcore ───────────────────────────┐
 (host/send_program.py)                (qemu_top)       │  qstate_ctrl ──alamat/WE──► qstate_ram (2^N x 32 bit)      │
                                                        │      │  ▲                        │ dout A/B               │
                                                        │      ▼  │ valid_out/hasil        ▼                        │
                                                        │   gate_engine (butterfly 2x2 kompleks, 4 tahap) ◄──────┘  │
                                                        └──────────────────────────────┬──────────────────────────────┘
                                          scan state (re²+im²) ◄───── rd_addr/rd_data ──┘ ──► LED[15:0]
```

### Siklus per pasangan

| State | Aksi |
|---|---|
| `S_ISSUE` | alamat `i0`, `i1` ke dua port RAM (atau lewati bila control = 0) |
| `S_CAPTURE` | data RAM valid, `gate_engine` mengambilnya |
| `S_WAIT_ENG` | 4 clock pipeline engine; saat `valid_out` hasil ditulis balik |
| `S_NEXT` | pasangan berikutnya / selesai |

≈ 7 clock per pasangan: 4 qubit ≈ 60 clock (~0,6 µs @ 100 MHz), 10 qubit ≈ 3.600 clock (~36 µs) per gerbang.

---

## 2. Struktur folder

```
src/     gate_engine.vhd  qstate_ram.vhd  qstate_ctrl.vhd  qcore.vhd  uart_rx.vhd  qemu_top.vhd
sim/     tb_gate_engine.vhd  tb_qcore.vhd  tb_qemu_top.vhd  + prog_*.mem / golden_*.mem / gate_vectors.mem (dibuat qsim.py)
ref/     qsim.py            model referensi float + fixed-point bit-accurate + assembler
host/    send_program.py    kirim program ke board lewat UART
constr/  basys3.xdc
scripts/ create_project.tcl  sim_ghdl.sh
```

| File | Peran |
|---|---|
| `gate_engine.vhd` | Butterfly 2×2 kompleks, pipeline 4 tahap (operand → 16 perkalian/DSP → jumlah 34 bit → round+saturasi). Tabel koefisien gerbang di dalamnya. |
| `qstate_ram.vhd` | Memori state vector: 2ᴺ entri × 32 bit `{re[31:16], im[15:0]}`, dual-port, read-first, atribut `ram_style = block`. |
| `qstate_ctrl.vhd` | FSM: dekode instruksi, iterasi pasangan indeks, gerbang terkontrol, `RESET`, validasi operand (operand salah → NOP). |
| `qcore.vhd` | Gabungan RAM + engine + ctrl, tanpa pin/UART (dipakai testbench). |
| `uart_rx.vhd` | Penerima UART 8N1 (generic `CLK_HZ`, `BAUD`), sinkronisasi 2 FF. |
| `qemu_top.vhd` | Top Basys 3: UART → instruksi 16-bit → `qcore` → scan state → LED. RESET otomatis saat power-up/`btnC`. |
| `tb_gate_engine.vhd` | Membandingkan engine dengan `gate_vectors.mem` (±380 vektor, semua gerbang, RY/RZ param 0..15, kasus saturasi). |
| `tb_qcore.vhd` | Menjalankan 10 program dan membandingkan seluruh state vector dengan `golden_*.mem`. |
| `tb_qemu_top.vhd` | Uji ujung-ke-ujung: byte UART masuk ke `qemu_top`, lalu LED diperiksa (boot, Bell, X, superposisi 4 qubit). Tanpa file `.mem`. |
| `ref/qsim.py` | Model float (NumPy), model fixed-point yang identik bit-per-bit dengan hardware, assembler, generator `.mem`. |
| `host/send_program.py` | Mengirim program (`--demo`, `--asm`, atau `--mem`) ke board. |

---

## 3. Format angka

| Besaran | Format | Catatan |
|---|---|---|
| Amplitudo (re, im) | **Q1.15**, int16 | 1,0 ≈ `0x7FFF` |
| Koefisien gerbang | **Q2.14**, int16 | 1,0 = `0x4000` (Q1.15 tidak bisa menyimpan 1,0, makanya dibedakan) |
| Akumulator | 34 bit | 4 suku × (16×16 bit), dijumlah penuh sebelum dipotong |
| Pembulatan | `(x + 8192) >>> 14` | *round-half-up*, bukan *truncation* (truncation membuat norma state menyusut) |
| Saturasi | ke int16 | |
| Entri RAM | 32 bit | `{re, im}` |

---

## 4. Instruksi dan assembly

Instruksi 16-bit: `[opcode:4][target:4][control:4][param:4]`, `control = F` berarti tanpa kontrol.

| Opcode | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | F |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Mnemonic | NOP | H | X | Y | Z | S | T | RY | RZ | MEASURE* | RESET |

\* `MEASURE` dicadangkan (saat ini sama dengan NOP).
`RY`/`RZ`: θ = `param` × π/8, `param` 0..15 (koefisien dari tabel cos/sin(`param`·π/16)).

Sintaks assembly (`ref/qsim.py`, komentar dengan `#`):

```
RESET             # state kembali ke |0...0>
H 0               # Hadamard pada qubit 0
CNOT 0 1          # control=0, target=1   (alias: CX)
CZ 0 1            # gerbang terkontrol: C + {H X Y Z S T}
CS 1 2            # controlled-S
RY 0 4            # rotasi, param 0..15
CRY 0 1 8         # controlled-RY: control target param
```

---

## 5. Alur kerja

### a. Siapkan file simulasi dan cek model
```bash
python ref/qsim.py gen      # buat sim/*.mem (program, golden, vektor gate)
python ref/qsim.py check    # float vs fixed-point + cek tabel trig di gate_engine.vhd
python ref/qsim.py list     # daftar program demo
```

### b. Buat proyek Vivado
```bash
vivado -mode batch -source scripts/create_project.tcl
```
(atau *Tools → Run Tcl Script*). Skrip menetapkan semua file `.vhd` sebagai **VHDL 2008**, top = `qemu_top`, top simulasi = `tb_qcore`.

### c. Simulasi (urutan yang disarankan)
1. `tb_gate_engine` — ganti top simulasi: `set_property top tb_gate_engine [get_filesets sim_1]`.
2. `tb_qcore` — harus mencetak `ALL TESTS PASSED`. Hasil harus cocok **bit per bit** dengan `qsim.py`.
3. `tb_qemu_top` — uji jalur UART → core → LED; mencetak `ALL TESTS PASSED`.
4. Bila xsim tidak menemukan `.mem`, set generic `SIM_DIR` ke path absolut folder `sim/` (lihat komentar di `create_project.tcl`).

Alternatif tanpa Vivado: `scripts/sim_ghdl.sh [tb_qcore|tb_gate_engine|tb_qemu_top]` (butuh GHDL).

### d. Sintesis dan program board
*Run Synthesis → Implementation → Generate Bitstream → Program Device.* Periksa laporan utilization (BRAM/DSP) dan timing 100 MHz.

### e. Jalankan program dari PC
```bash
pip install pyserial
python host/send_program.py --list                     # demo + port serial
python host/send_program.py COM5 --demo bell           # Linux: /dev/ttyUSB1
python host/send_program.py COM5 --asm sirkuitku.asm
python host/send_program.py --demo grover2 --dry-run   # tanpa board
```

---

## 6. Membaca hasil di board

Setelah tiap instruksi selesai, `qemu_top` membaca semua amplitudo, menghitung p = re² + im², lalu **LED[i] menyala bila p(state i) ≥ ambang**.
Ambang diatur **`sw[2:0]` = k**: ambang = 0,25 / 2ᵏ  (k=0: 0,25 · k=1: 0,125 · k=2: 0,0625 · … · k=7: 1/512).
Hanya 16 state pertama yang ditampilkan. `btnC` = reset (hanya LED0 menyala).
Indeks LED = nilai biner state dengan qubit 0 sebagai bit terendah.

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

Untuk osilasi Rabi, kirim `RESET` lalu `RY 0 k` dengan k = 0..15 dan amati probabilitas |1⟩ = sin²(kπ/16).

---

## 7. Verifikasi dan analisis untuk laporan

- **Golden model:** `qsim.py` menyediakan model float dan model fixed-point yang identik dengan hardware. Testbench membandingkan keduanya tanpa toleransi.
- **Error numerik:** untuk program demo, error maksimum model fixed-point vs float sekitar 10⁻⁴ (lihat keluaran `qsim.py gen`).
  Buat plot *fidelity vs jumlah gerbang* (ulangi H–H–… atau Grover berkali-kali) untuk menunjukkan drift akibat pembulatan.
- **Resource:** bandingkan LUT/FF/BRAM/DSP dan timing untuk `N_QUBITS` = 4, 6, 8, 10 (ubah generic di `qemu_top`/`create_project.tcl`).
  Catatan: LED hanya menampilkan 16 state pertama; `.mem` di `sim/` dibuat untuk 4 qubit (`qsim.py gen --n N` untuk N lain).
- **Kecepatan:** bandingkan waktu eksekusi hardware (≈ 7 clock/pasangan) dengan NumPy/Qiskit untuk sirkuit yang sama.

---

## 8. Status dan batasan

- Model Python sudah diuji: fidelity > 0,999 terhadap model float untuk semua demo; tabel trig di VHDL cocok dengan `qsim.py`.
- **Kode VHDL belum pernah dikompilasi, disimulasikan, atau disintesis saat README ini dibuat.** Jalankan `tb_gate_engine` dan `tb_qcore` lebih dulu dan perbaiki bila ada error sintaks atau mismatch.
- Periksa di laporan Vivado apakah `qstate_ram` benar-benar menjadi BRAM, jumlah DSP (perkiraan 16), dan WNS timing @ 100 MHz.
- Pin di `basys3.xdc` diambil dari master XDC Digilent; cocokkan dengan file resmi.
- Belum ada: `MEASURE` (sampling dengan LFSR + histogram), UART TX untuk mengirim state ke PC, dan CORDIC (rotasi sekarang memakai tabel 16 sudut).
- Presisi 16 bit: error akumulasi tumbuh seiring banyaknya gerbang.

## 9. Rencana pengembangan

1. Modul `MEASURE`: LFSR 32-bit + distribusi kumulatif → histogram ribuan shot.
2. `uart_tx`: kirim state vector/histogram ke PC untuk plot dan perbandingan dengan NumPy.
3. Tabel sudut lebih halus (param > 4 bit) atau CORDIC untuk RY/RZ.
4. Pipeline penuh antar-pasangan (target ≈ 1 pasangan/clock).
5. Pulse-level / model Bloch (osilasi Rabi dengan T1/T2) sebagai tambahan bertema *quantum control*.
