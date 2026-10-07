#!/usr/bin/env bash
# Simulasi dengan GHDL (VHDL-2008). Jalankan dari folder scripts/ :
#   ./sim_ghdl.sh [tb_qcore|tb_gate_engine|tb_qemu_top]
# -frelaxed diperlukan karena qstate_ram memakai shared variable bertipe biasa (pola RAM Xilinx).
set -e
TB=${1:-tb_qcore}
FLAGS="--std=08 -frelaxed --workdir=../build"
cd "$(dirname "$0")/../sim"          # .mem dicari relatif terhadap folder sim/
mkdir -p ../build
ghdl -a $FLAGS ../src/gate_engine.vhd ../src/qstate_ram.vhd ../src/qstate_ctrl.vhd \
        ../src/qcore.vhd ../src/uart_rx.vhd ../src/qemu_top.vhd \
        tb_gate_engine.vhd tb_qcore.vhd tb_qemu_top.vhd
ghdl -e $FLAGS "$TB"
ghdl -r $FLAGS "$TB"
