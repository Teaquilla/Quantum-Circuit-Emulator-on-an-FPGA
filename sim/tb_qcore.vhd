-- tb_qcore.vhd
-- Menjalankan program (prog_<nama>.mem, 1 instruksi 16-bit hex per baris) pada qcore, lalu membaca
-- seluruh state vector lewat port rd_* dan membandingkannya BIT PER BIT dengan golden_<nama>.mem
-- ({re16, im16} per baris) dari ref/qsim.py. Butuh VHDL-2008. Default N_QUBITS = 4 (sesuai file .mem).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_qcore is
    generic (
        N_QUBITS : positive := 4;
        SIM_DIR  : string   := ""
    );
end entity tb_qcore;

architecture sim of tb_qcore is
    signal clk         : std_logic := '0';
    signal rst         : std_logic := '1';
    signal instr_valid : std_logic := '0';
    signal instr       : std_logic_vector(15 downto 0) := (others => '0');
    signal busy, done  : std_logic;
    signal rd_addr     : unsigned(N_QUBITS - 1 downto 0) := (others => '0');
    signal rd_data     : std_logic_vector(31 downto 0);
    signal sim_done    : boolean := false;
begin

    clk_gen : process
    begin
        while not sim_done loop
            clk <= '0'; wait for 5 ns;
            clk <= '1'; wait for 5 ns;
        end loop;
        wait;
    end process;

    dut : entity work.qcore
        generic map (N_QUBITS => N_QUBITS)
        port map (
            clk => clk, rst => rst,
            instr_valid => instr_valid, instr => instr,
            busy => busy, done => done,
            rd_addr => rd_addr, rd_data => rd_data
        );

    stim : process
        variable total_err : integer := 0;
        variable n_tests   : integer := 0;
        variable n_fail    : integer := 0;

        procedure run_test (tname : in string) is
            file     fp, fg : text;
            variable l      : line;
            variable w      : std_logic_vector(15 downto 0);
            variable g      : std_logic_vector(31 downto 0);
            variable errs   : integer := 0;
            variable idx    : integer := 0;
            variable n_ins  : integer := 0;
        begin
            -- 1) jalankan program
            file_open(fp, SIM_DIR & "prog_" & tname & ".mem", read_mode);
            while not endfile(fp) loop
                readline(fp, l);
                if l'length > 0 then
                    hread(l, w);
                    wait until rising_edge(clk);
                    instr <= w;
                    instr_valid <= '1';
                    wait until rising_edge(clk);
                    instr_valid <= '0';
                    wait until done = '1' for 50 us;
                    if done /= '1' then
                        errs := errs + 1;
                        report tname & ": timeout menunggu done pada instruksi " &
                               integer'image(n_ins) severity error;
                        exit;
                    end if;
                    wait until rising_edge(clk);
                    n_ins := n_ins + 1;
                end if;
            end loop;
            file_close(fp);

            -- 2) bandingkan seluruh state vector dengan golden
            file_open(fg, SIM_DIR & "golden_" & tname & ".mem", read_mode);
            while not endfile(fg) loop
                readline(fg, l);
                if l'length > 0 then
                    hread(l, g);
                    rd_addr <= to_unsigned(idx, N_QUBITS);
                    wait until rising_edge(clk);
                    wait until rising_edge(clk);
                    wait for 1 ns;
                    if rd_data /= g then
                        errs := errs + 1;
                        report tname & ": state[" & integer'image(idx) & "] got " &
                               to_hstring(rd_data) & " exp " & to_hstring(g) severity error;
                    end if;
                    idx := idx + 1;
                end if;
            end loop;
            file_close(fg);

            n_tests := n_tests + 1;
            if errs = 0 then
                report "PASS  " & tname & " (" & integer'image(n_ins) & " instruksi)" severity note;
            else
                n_fail := n_fail + 1;
                total_err := total_err + errs;
                report "FAIL  " & tname & " (" & integer'image(errs) & " mismatch)" severity error;
            end if;
        end procedure;

    begin
        rst <= '1';
        wait for 100 ns;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        run_test("bell");
        run_test("ghz4");
        run_test("grover2");
        run_test("dj3_balanced");
        run_test("dj3_constant");
        run_test("qft3");
        run_test("rabi_04");
        run_test("rabi_08");
        run_test("rz_04");
        run_test("cry");

        report "tb_qcore: " & integer'image(n_tests - n_fail) & "/" & integer'image(n_tests) &
               " program lulus" severity note;
        if n_fail = 0 then
            report "tb_qcore: ALL TESTS PASSED" severity note;
        else
            report "tb_qcore: ADA YANG GAGAL" severity error;
        end if;
        sim_done <= true;
        wait;
    end process;

end architecture sim;
