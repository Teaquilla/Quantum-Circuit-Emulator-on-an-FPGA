-- qcore.vhd
-- Inti emulator: qstate_ram + gate_engine + qstate_ctrl. Tanpa UART/pin, jadi mudah disimulasikan.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity qcore is
    generic (
        N_QUBITS : positive := 4
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;
        instr_valid : in  std_logic;                       -- pulsa 1 clock saat busy = '0'
        instr       : in  std_logic_vector(15 downto 0);
        busy        : out std_logic;
        done        : out std_logic;                       -- pulsa 1 clock
        rd_addr     : in  unsigned(N_QUBITS - 1 downto 0); -- baca state saat idle
        rd_data     : out std_logic_vector(31 downto 0)    -- valid 1 clock setelah rd_addr stabil
    );
end entity qcore;

architecture rtl of qcore is
    signal a_we, b_we         : std_logic;
    signal a_addr, b_addr     : unsigned(N_QUBITS - 1 downto 0);
    signal a_din, b_din       : std_logic_vector(31 downto 0);
    signal a_dout, b_dout     : std_logic_vector(31 downto 0);

    signal eng_valid_in       : std_logic;
    signal eng_valid_out      : std_logic;
    signal eng_opcode         : std_logic_vector(3 downto 0);
    signal eng_param          : std_logic_vector(3 downto 0);
    signal eng_a_out          : std_logic_vector(31 downto 0);
    signal eng_b_out          : std_logic_vector(31 downto 0);
begin

    u_ctrl : entity work.qstate_ctrl
        generic map (N_QUBITS => N_QUBITS)
        port map (
            clk           => clk,
            rst           => rst,
            instr_valid   => instr_valid,
            instr         => instr,
            busy          => busy,
            done          => done,
            rd_addr       => rd_addr,
            a_we          => a_we,
            a_addr        => a_addr,
            a_din         => a_din,
            b_we          => b_we,
            b_addr        => b_addr,
            b_din         => b_din,
            eng_valid_in  => eng_valid_in,
            eng_opcode    => eng_opcode,
            eng_param     => eng_param,
            eng_valid_out => eng_valid_out,
            eng_a_out     => eng_a_out,
            eng_b_out     => eng_b_out
        );

    u_ram : entity work.qstate_ram
        generic map (N_QUBITS => N_QUBITS)
        port map (
            clk    => clk,
            a_we   => a_we,
            a_addr => a_addr,
            a_din  => a_din,
            a_dout => a_dout,
            b_we   => b_we,
            b_addr => b_addr,
            b_din  => b_din,
            b_dout => b_dout
        );

    u_eng : entity work.gate_engine
        port map (
            clk       => clk,
            valid_in  => eng_valid_in,
            opcode    => eng_opcode,
            param     => eng_param,
            a_in      => a_dout,
            b_in      => b_dout,
            valid_out => eng_valid_out,
            a_out     => eng_a_out,
            b_out     => eng_b_out
        );

    rd_data <= a_dout;

end architecture rtl;
