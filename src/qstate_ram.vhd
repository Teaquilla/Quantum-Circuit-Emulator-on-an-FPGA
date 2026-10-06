-- qstate_ram.vhd
-- Memori state vector: 2^N_QUBITS amplitudo kompleks, tiap entri 32 bit {re[31:16], im[15:0]} (Q1.15).
-- Dua port baca/tulis sinkron (read-first), diharapkan terinferensi sebagai BRAM (cek laporan utilization).
-- Port A juga dipakai untuk membaca state saat core idle (dump/scan).

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
    signal ram : ram_t := (others => (others => '0'));

    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";
begin

    process (clk)
    begin
        if rising_edge(clk) then
            if a_we = '1' then
                ram(to_integer(a_addr)) <= a_din;
            end if;
            a_dout <= ram(to_integer(a_addr));

            if b_we = '1' then
                ram(to_integer(b_addr)) <= b_din;
            end if;
            b_dout <= ram(to_integer(b_addr));
        end if;
    end process;

end architecture rtl;
