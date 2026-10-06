-- uart_rx.vhd
-- Penerima UART 8N1. 'valid' = pulsa 1 clock, 'data' stabil sampai start bit berikutnya.

library ieee;
use ieee.std_logic_1164.all;

entity uart_rx is
    generic (
        CLK_HZ : positive := 100_000_000;
        BAUD   : positive := 115_200
    );
    port (
        clk   : in  std_logic;
        rx    : in  std_logic;
        data  : out std_logic_vector(7 downto 0);
        valid : out std_logic
    );
end entity uart_rx;

architecture rtl of uart_rx is
    constant CPB : positive := CLK_HZ / BAUD;       -- clock per bit

    type state_t is (S_IDLE, S_START, S_DATA, S_STOP);
    signal state   : state_t := S_IDLE;

    signal rx_s1, rx_s2 : std_logic := '1';         -- sinkronisasi 2 flip-flop
    signal cnt     : integer range 0 to CPB - 1 := 0;
    signal bit_idx : integer range 0 to 7 := 0;
    signal sh      : std_logic_vector(7 downto 0) := (others => '0');
    signal valid_r : std_logic := '0';
begin

    data  <= sh;
    valid <= valid_r;

    process (clk)
    begin
        if rising_edge(clk) then
            rx_s1   <= rx;
            rx_s2   <= rx_s1;
            valid_r <= '0';

            case state is

                when S_IDLE =>
                    if rx_s2 = '0' then                 -- tepi turun = start bit
                        cnt   <= 0;
                        state <= S_START;
                    end if;

                when S_START =>                         -- tunggu tengah start bit
                    if cnt = CPB / 2 - 1 then
                        cnt <= 0;
                        if rx_s2 = '0' then
                            bit_idx <= 0;
                            state   <= S_DATA;
                        else
                            state <= S_IDLE;            -- glitch
                        end if;
                    else
                        cnt <= cnt + 1;
                    end if;

                when S_DATA =>                          -- sampel di tengah tiap bit, LSB dulu
                    if cnt = CPB - 1 then
                        cnt <= 0;
                        sh  <= rx_s2 & sh(7 downto 1);
                        if bit_idx = 7 then
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 1;
                        end if;
                    else
                        cnt <= cnt + 1;
                    end if;

                when S_STOP =>                          -- tengah stop bit
                    if cnt = CPB - 1 then
                        cnt   <= 0;
                        state <= S_IDLE;
                        if rx_s2 = '1' then
                            valid_r <= '1';
                        end if;
                    else
                        cnt <= cnt + 1;
                    end if;

            end case;
        end if;
    end process;

end architecture rtl;
