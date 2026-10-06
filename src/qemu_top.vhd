-- qemu_top.vhd  (top level Basys 3)
--
--   PC --UART 115200 8N1--> uart_rx --> perakit instruksi 16-bit --> qcore --> scan state --> LED
--
-- Protokol UART: tiap instruksi = 2 byte, byte tinggi dulu. Instruksi dieksekusi satu per satu
-- (host/send_program.py). Jika di tengah instruksi tidak ada byte baru selama ~10 ms, byte
-- setengah-jadi dibuang (resync otomatis).
--
-- Tampilan: setelah tiap instruksi selesai, semua amplitudo dibaca, dihitung p = re^2 + im^2,
-- dan LED[i] menyala bila p(state i) >= ambang. Hanya 16 state pertama yang ditampilkan.
--   sw[2:0] = k  ->  ambang = 2^(28-k) dalam skala 1.0 = 2^30  (k=0: 0.25, k=1: 0.125, ... k=7: 1/512)
-- Setelah reset (btnC) atau power-up, core menjalankan RESET sendiri -> hanya LED0 menyala.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity qemu_top is
    generic (
        N_QUBITS : positive := 4;
        CLK_HZ   : positive := 100_000_000;
        BAUD     : positive := 115_200
    );
    port (
        clk  : in  std_logic;
        btnC : in  std_logic;
        RsRx : in  std_logic;
        sw   : in  std_logic_vector(2 downto 0);
        led  : out std_logic_vector(15 downto 0)
    );
end entity qemu_top;

architecture rtl of qemu_top is

    constant TMO_MAX : integer := CLK_HZ / 100;          -- 10 ms
    constant N_STATE : integer := 2 ** N_QUBITS;

    -- reset sinkron (aktif saat power-up selama 2 clock)
    signal rst_s1, rst_s2 : std_logic := '1';
    signal rst            : std_logic;
    signal sw_s1, sw_s2   : std_logic_vector(2 downto 0) := (others => '0');

    -- UART
    signal rx_data  : std_logic_vector(7 downto 0);
    signal rx_valid : std_logic;

    -- perakit instruksi
    signal hi_have    : std_logic := '0';
    signal hi_byte    : std_logic_vector(7 downto 0) := (others => '0');
    signal tmo        : integer range 0 to TMO_MAX := 0;
    signal pend_valid : std_logic := '0';
    signal pend_instr : std_logic_vector(15 downto 0) := (others => '0');

    -- ke core
    signal instr_r       : std_logic_vector(15 downto 0) := (others => '0');
    signal instr_valid_r : std_logic := '0';
    signal rd_addr_r     : unsigned(N_QUBITS - 1 downto 0) := (others => '0');
    signal rd_data       : std_logic_vector(31 downto 0);
    signal core_done     : std_logic;

    -- FSM top
    type tstate_t is (T_BOOT, T_ISSUED, T_RUN, T_IDLE,
                      T_SC_ADDR, T_SC_WAIT, T_SC_LATCH, T_SC_MUL, T_SC_CMP);
    signal tstate : tstate_t := T_BOOT;

    signal idx   : integer range 0 to N_STATE - 1 := 0;
    signal re_r  : signed(15 downto 0) := (others => '0');
    signal im_r  : signed(15 downto 0) := (others => '0');
    signal p_r   : unsigned(31 downto 0) := (others => '0');
    signal led_r : std_logic_vector(15 downto 0) := (others => '0');

begin

    rst <= rst_s2;
    led <= led_r;

    u_rx : entity work.uart_rx
        generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
        port map (clk => clk, rx => RsRx, data => rx_data, valid => rx_valid);

    u_core : entity work.qcore
        generic map (N_QUBITS => N_QUBITS)
        port map (
            clk         => clk,
            rst         => rst,
            instr_valid => instr_valid_r,
            instr       => instr_r,
            busy        => open,
            done        => core_done,
            rd_addr     => rd_addr_r,
            rd_data     => rd_data
        );

    process (clk)
        variable thr : unsigned(31 downto 0);
    begin
        if rising_edge(clk) then
            rst_s1 <= btnC;
            rst_s2 <= rst_s1;
            sw_s1  <= sw;
            sw_s2  <= sw_s1;

            instr_valid_r <= '0';                        -- default: pulsa 1 clock

            if rst = '1' then
                tstate     <= T_BOOT;
                hi_have    <= '0';
                tmo        <= 0;
                pend_valid <= '0';
                led_r      <= (others => '0');
            else
                ------------------------------------------------ FSM
                case tstate is

                    when T_BOOT =>                       -- RESET otomatis setelah reset board
                        instr_r       <= x"F000";
                        instr_valid_r <= '1';
                        tstate        <= T_ISSUED;

                    when T_ISSUED =>                     -- instr_valid_r = '1' pada clock ini
                        tstate <= T_RUN;

                    when T_RUN =>
                        if core_done = '1' then
                            idx    <= 0;
                            tstate <= T_SC_ADDR;
                        end if;

                    when T_IDLE =>
                        if pend_valid = '1' then
                            instr_r       <= pend_instr;
                            instr_valid_r <= '1';
                            pend_valid    <= '0';
                            tstate        <= T_ISSUED;
                        end if;

                    when T_SC_ADDR =>
                        rd_addr_r <= to_unsigned(idx, N_QUBITS);
                        tstate    <= T_SC_WAIT;

                    when T_SC_WAIT =>                    -- RAM menangkap alamat
                        tstate <= T_SC_LATCH;

                    when T_SC_LATCH =>                   -- rd_data valid
                        re_r   <= signed(rd_data(31 downto 16));
                        im_r   <= signed(rd_data(15 downto 0));
                        tstate <= T_SC_MUL;

                    when T_SC_MUL =>
                        p_r    <= unsigned(re_r * re_r) + unsigned(im_r * im_r);
                        tstate <= T_SC_CMP;

                    when T_SC_CMP =>
                        thr := shift_left(to_unsigned(1, 32), 28 - to_integer(unsigned(sw_s2)));
                        if idx < 16 then
                            if p_r >= thr then
                                led_r(idx) <= '1';
                            else
                                led_r(idx) <= '0';
                            end if;
                        end if;
                        if idx = N_STATE - 1 then
                            tstate <= T_IDLE;
                        else
                            idx    <= idx + 1;
                            tstate <= T_SC_ADDR;
                        end if;

                end case;

                ------------------------------------------------ perakit byte -> instruksi
                if rx_valid = '1' then
                    tmo <= 0;
                    if hi_have = '0' then
                        hi_byte <= rx_data;
                        hi_have <= '1';
                    else
                        hi_have    <= '0';
                        pend_instr <= hi_byte & rx_data;
                        pend_valid <= '1';               -- menimpa consume di atas bila bersamaan
                    end if;
                elsif hi_have = '1' then
                    if tmo = TMO_MAX then
                        hi_have <= '0';
                        tmo     <= 0;
                    else
                        tmo <= tmo + 1;
                    end if;
                end if;

            end if;
        end if;
    end process;

end architecture rtl;
