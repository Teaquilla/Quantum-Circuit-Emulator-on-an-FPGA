-- tb_qemu_top.vhd
-- Uji ujung-ke-ujung: kirim byte UART ke qemu_top (seperti host/send_program.py), lalu periksa LED.
-- CLK_HZ/BAUD diperkecil (10 clock per bit) supaya simulasi singkat; logika desain sama.
-- Tidak butuh file .mem. Butuh VHDL-2008.
--
-- Kasus:
--   1. setelah reset/boot               -> hanya LED0 menyala              (0x0001)
--   2. H 0 ; CNOT 0 1  (Bell)           -> LED0 dan LED3                   (0x0009)
--   3. RESET ; X 1                      -> state |0010>  -> LED2           (0x0004)
--   4. RESET ; H 0..3, sw = 011         -> 16 state seragam 1/16 >= 1/32   (0xFFFF)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_qemu_top is
end entity tb_qemu_top;

architecture sim of tb_qemu_top is
    constant CLK_HZ : positive := 1_000_000;
    constant BAUD   : positive := 100_000;
    constant CPB    : positive := CLK_HZ / BAUD;       -- 10 clock per bit
    constant TCLK   : time     := 10 ns;

    signal clk      : std_logic := '0';
    signal btnC     : std_logic := '1';
    signal RsRx     : std_logic := '1';
    signal sw       : std_logic_vector(2 downto 0) := "000";
    signal led      : std_logic_vector(15 downto 0);
    signal sim_done : boolean := false;
begin

    clk_gen : process
    begin
        while not sim_done loop
            clk <= '0'; wait for TCLK / 2;
            clk <= '1'; wait for TCLK / 2;
        end loop;
        wait;
    end process;

    dut : entity work.qemu_top
        generic map (N_QUBITS => 4, CLK_HZ => CLK_HZ, BAUD => BAUD)
        port map (clk => clk, btnC => btnC, RsRx => RsRx, sw => sw, led => led);

    stim : process
        variable fails : integer := 0;

        procedure send_byte (b : in std_logic_vector(7 downto 0)) is
        begin
            RsRx <= '0';                                -- start bit
            wait for CPB * TCLK;
            for i in 0 to 7 loop                        -- data, LSB dulu
                RsRx <= b(i);
                wait for CPB * TCLK;
            end loop;
            RsRx <= '1';                                -- stop bit
            wait for CPB * TCLK;
        end procedure;

        procedure send_instr (w : in std_logic_vector(15 downto 0)) is
        begin
            send_byte(w(15 downto 8));
            send_byte(w(7 downto 0));
            wait for 1000 * TCLK;                       -- beri waktu eksekusi + scan LED
        end procedure;

        procedure check (exp : in std_logic_vector(15 downto 0); what : in string) is
        begin
            wait for 1000 * TCLK;
            if led = exp then
                report "PASS  " & what severity note;
            else
                fails := fails + 1;
                report "FAIL  " & what & " : led=" & to_hstring(led) &
                       " exp=" & to_hstring(exp) severity error;
            end if;
        end procedure;

    begin
        -- reset lalu boot (core menjalankan RESET sendiri)
        btnC <= '1';
        wait for 200 ns;
        btnC <= '0';
        wait for 3000 * TCLK;
        check(x"0001", "boot: |0000>");

        -- Bell: H 0 ; CNOT 0 1
        send_instr(x"10F0");
        send_instr(x"2100");
        check(x"0009", "Bell: LED0 + LED3");

        -- RESET ; X 1
        send_instr(x"F000");
        send_instr(x"21F0");
        check(x"0004", "X pada qubit 1: LED2");

        -- RESET ; H pada keempat qubit, ambang diturunkan (sw = 011 -> 1/32)
        sw <= "011";
        send_instr(x"F000");
        send_instr(x"10F0");
        send_instr(x"11F0");
        send_instr(x"12F0");
        send_instr(x"13F0");
        check(x"FFFF", "superposisi seragam 4 qubit: semua LED");

        if fails = 0 then
            report "tb_qemu_top: ALL TESTS PASSED" severity note;
        else
            report "tb_qemu_top: " & integer'image(fails) & " kasus gagal" severity error;
        end if;
        sim_done <= true;
        wait;
    end process;

end architecture sim;
