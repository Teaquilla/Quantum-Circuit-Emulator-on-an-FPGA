-- tb_gate_engine.vhd
-- Membandingkan gate_engine dengan vektor dari ref/qsim.py (gate_vectors.mem).
-- Tiap baris: opcode param a b exp_a exp_b (hex; a/b/exp = {re16, im16}). Harus cocok BIT PER BIT.
-- Butuh VHDL-2008 (to_hstring). Jalankan dari folder sim/ atau set generic SIM_DIR.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_gate_engine is
    generic (
        SIM_DIR : string := ""
    );
end entity tb_gate_engine;

architecture sim of tb_gate_engine is
    signal clk       : std_logic := '0';
    signal valid_in  : std_logic := '0';
    signal valid_out : std_logic;
    signal opcode    : std_logic_vector(3 downto 0) := (others => '0');
    signal param     : std_logic_vector(3 downto 0) := (others => '0');
    signal a_in      : std_logic_vector(31 downto 0) := (others => '0');
    signal b_in      : std_logic_vector(31 downto 0) := (others => '0');
    signal a_out     : std_logic_vector(31 downto 0);
    signal b_out     : std_logic_vector(31 downto 0);
    signal sim_done  : boolean := false;
begin

    clk_gen : process
    begin
        while not sim_done loop
            clk <= '0'; wait for 5 ns;
            clk <= '1'; wait for 5 ns;
        end loop;
        wait;
    end process;

    dut : entity work.gate_engine
        port map (
            clk => clk, valid_in => valid_in, opcode => opcode, param => param,
            a_in => a_in, b_in => b_in,
            valid_out => valid_out, a_out => a_out, b_out => b_out
        );

    stim : process
        file     f   : text;
        variable l   : line;
        variable op  : std_logic_vector(3 downto 0);
        variable par : std_logic_vector(3 downto 0);
        variable a, b, ea, eb : std_logic_vector(31 downto 0);
        variable n, errs      : integer := 0;
    begin
        wait for 50 ns;
        file_open(f, SIM_DIR & "gate_vectors.mem", read_mode);

        while not endfile(f) loop
            readline(f, l);
            if l'length > 0 then
                hread(l, op);  hread(l, par);
                hread(l, a);   hread(l, b);
                hread(l, ea);  hread(l, eb);

                wait until rising_edge(clk);
                opcode <= op;  param <= par;
                a_in   <= a;   b_in  <= b;
                valid_in <= '1';
                wait until rising_edge(clk);
                valid_in <= '0';

                wait until valid_out = '1' for 200 ns;
                wait for 1 ns;
                if valid_out /= '1' then
                    errs := errs + 1;
                    report "vektor " & integer'image(n) & ": valid_out tidak muncul" severity error;
                elsif a_out /= ea or b_out /= eb then
                    errs := errs + 1;
                    report "vektor " & integer'image(n) &
                           " op=" & to_hstring(op) & " par=" & to_hstring(par) &
                           " a=" & to_hstring(a) & " b=" & to_hstring(b) &
                           " | got " & to_hstring(a_out) & " " & to_hstring(b_out) &
                           " | exp " & to_hstring(ea) & " " & to_hstring(eb)
                           severity error;
                end if;
                n := n + 1;
                wait until rising_edge(clk);
            end if;
        end loop;
        file_close(f);

        if errs = 0 then
            report "tb_gate_engine: PASS (" & integer'image(n) & " vektor)" severity note;
        else
            report "tb_gate_engine: FAIL (" & integer'image(errs) & " dari " &
                   integer'image(n) & " vektor salah)" severity error;
        end if;
        sim_done <= true;
        wait;
    end process;

end architecture sim;
