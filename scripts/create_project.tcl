# create_project.tcl : buat proyek Vivado dari nol.
#   vivado -mode batch -source scripts/create_project.tcl      (atau Tools > Run Tcl Script)
# Hasil: folder vivado/ (sudah di .gitignore). Jalankan ulang kapan saja, folder lama ditimpa.

set proj_name quantum_fpga
set root      [file normalize [file join [file dirname [info script]] ..]]
set part      xc7a35tcpg236-1

create_project -force $proj_name [file join $root vivado] -part $part

# ---- desain (VHDL-2008)
set src_files [glob -directory [file join $root src] *.vhd]
add_files -fileset sources_1 $src_files
set_property file_type {VHDL 2008} [get_files $src_files]
# qstate_ram memakai shared variable (pola true-dual-port Xilinx) -> harus VHDL biasa, bukan 2008
set_property file_type {VHDL} [get_files [file join $root src qstate_ram.vhd]]
set_property top qemu_top [get_filesets sources_1]

# ---- constraint
add_files -fileset constrs_1 [file join $root constr basys3.xdc]

# ---- simulasi: testbench + file .mem (xsim menyalinnya ke folder simulasi)
set tb_files [glob -directory [file join $root sim] tb_*.vhd]
add_files -fileset sim_1 $tb_files
set_property file_type {VHDL 2008} [get_files $tb_files]
add_files -fileset sim_1 [glob -directory [file join $root sim] *.mem]
set_property top tb_qcore [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {2 ms} -objects [get_filesets sim_1]

# Bila xsim tidak menemukan file .mem, beri path absolut lewat generic SIM_DIR, misalnya:
#   set_property generic "SIM_DIR=\"[file join $root sim]/\"" [get_filesets sim_1]
# Untuk menjalankan tb_gate_engine: set_property top tb_gate_engine [get_filesets sim_1]

puts "Proyek dibuat di [file join $root vivado]. Selanjutnya: Run Simulation (tb_qcore), lalu Generate Bitstream."
