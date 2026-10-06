#!/usr/bin/env bash
# Simulasi dengan GHDL (VHDL-2008). Jalankan dari folder scripts/ :  ./sim_ghdl.sh [tb_qcore|tb_gate_engine|tb_qemu_top]
set -e
TB=${1:-tb_qcore}
cd "$(dirname "$0")/../sim"          # .mem dicari relatif terhadap folder sim/
mkdir -p ../build
ghdl -a --std=08 --workdir=../build ../src/gate_engine.vhd ../src/qstate_ram.vhd ../src/qstate_ctrl.vhd \
        ../src/qcore.vhd ../src/uart_rx.vhd ../src/qemu_top.vhd tb_gate_engine.vhd tb_qcore.vhd tb_qemu_top.vhd
ghdl -e --std=08 --workdir=../build "$TB"
ghdl -r --std=08 --workdir=../build "$TB"
