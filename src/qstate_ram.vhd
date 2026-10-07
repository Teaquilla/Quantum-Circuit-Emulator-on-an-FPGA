-- qstate_ram.vhd
-- Memori state vector: 2^N_QUBITS amplitudo kompleks, tiap entri 32 bit {re[31:16], im[15:0]} (Q1.15).
-- True dual-port, satu clock, read-first, memakai pola resmi Xilinx (UG901): shared variable +
-- satu process per port, supaya Vivado menginferensi BRAM (bukan 512 flip-flop).
-- Port A juga dipakai untuk membaca state saat core idle (dump/scan).
--
-- CATATAN: file ini harus bertipe "VHDL" (bukan VHDL 2008) di Vivado, karena shared variable
-- bertipe biasa (bukan protected type). scripts/create_project.tcl sudah mengaturnya.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity qstate_ram is
    generic (
        N_QUBITS : positive := 4
    );
    port (
        clk    : in  std_logic;
        -- port A
        a_we   : in  std_logic;
        a_addr : in  unsigned(N_QUBITS - 1 downto 0);
        a_din  : in  std_logic_vector(31 downto 0);
        a_dout : out std_logic_vector(31 downto 0);
        -- port B
        b_we   : in  std_logic;
        b_addr : in  unsigned(N_QUBITS - 1 downto 0);
        b_din  : in  std_logic_vector(31 downto 0);
        b_dout : out std_logic_vector(31 downto 0)
    );
end entity qstate_ram;

architecture rtl of qstate_ram is
    type ram_t is array (0 to 2 ** N_QUBITS - 1) of std_logic_vector(31 downto 0);
    shared variable ram : ram_t := (others => (others => '0'));

    attribute ram_style : string;
    attribute ram_style of ram : variable is "block";
begin

    port_a : process (clk)
    begin
        if rising_edge(clk) then
            a_dout <= ram(to_integer(a_addr));          -- baca dulu (read-first)
            if a_we = '1' then
                ram(to_integer(a_addr)) := a_din;
            end if;
        end if;
    end process port_a;

    port_b : process (clk)
    begin
        if rising_edge(clk) then
            b_dout <= ram(to_integer(b_addr));
            if b_we = '1' then
                ram(to_integer(b_addr)) := b_din;
            end if;
        end if;
    end process port_b;

end architecture rtl;
