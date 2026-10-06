-- gate_engine.vhd
-- Butterfly 2x2 kompleks untuk gerbang 1-qubit, pipeline 4 tahap.
--
--   [a']   [g00 g01] [a]
--   [b'] = [g10 g11] [b]        a, b : amplitudo Q1.15 {re[31:16], im[15:0]}
--                               g    : koefisien Q2.14 (1.0 = 0x4000), dipilih dari opcode
--
-- Latensi: valid_out naik 4 clock setelah clock tempat valid_in = '1' disampel.
--   tahap 0: register operand + koefisien
--   tahap 1: 16 perkalian 16x16 (dipetakan ke DSP48)
--   tahap 2: penjumlahan 4 suku (34 bit)
--   tahap 3: pembulatan (round-half-up) + saturasi ke int16
--
-- Peta opcode (harus sama dengan ref/qsim.py):
--   1 H   2 X   3 Y   4 Z   5 S   6 T   7 RY(param)   8 RZ(param)   lain: identitas
--   RY/RZ: theta = param * pi/8, koefisien dari tabel cos/sin(param*pi/16)
--   (tabel dibuat dengan "python ref/qsim.py trig"; "python ref/qsim.py check" memverifikasinya)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gate_engine is
    port (
        clk       : in  std_logic;
        valid_in  : in  std_logic;
        opcode    : in  std_logic_vector(3 downto 0);
        param     : in  std_logic_vector(3 downto 0);
        a_in      : in  std_logic_vector(31 downto 0);
        b_in      : in  std_logic_vector(31 downto 0);
        valid_out : out std_logic;
        a_out     : out std_logic_vector(31 downto 0);
        b_out     : out std_logic_vector(31 downto 0)
    );
end entity gate_engine;

architecture rtl of gate_engine is

    subtype s16 is signed(15 downto 0);

    type coef_t is record
        g00r, g00i : s16;
        g01r, g01i : s16;
        g10r, g10i : s16;
        g11r, g11i : s16;
    end record;

    type int_arr is array (0 to 15) of integer;
    constant COS_T : int_arr := (16384, 16069, 15137, 13623, 11585, 9102, 6270, 3196, 0, -3196, -6270, -9102, -11585, -13623, -15137, -16069);
    constant SIN_T : int_arr := (0, 3196, 6270, 9102, 11585, 13623, 15137, 16069, 16384, 16069, 15137, 13623, 11585, 9102, 6270, 3196);

    constant ONE : integer := 16384;   -- 1.0   dalam Q2.14
    constant HR  : integer := 11585;   -- 1/sqrt(2) dalam Q2.14

    function c16 (v : integer) return s16 is
    begin
        return to_signed(v, 16);
    end function;

    function coeffs (op : std_logic_vector(3 downto 0);
                     p  : std_logic_vector(3 downto 0)) return coef_t is
        variable r : coef_t;
        variable k : integer range 0 to 15;
    begin
        k := to_integer(unsigned(p));
        -- default: identitas
        r := (g00r => c16(ONE), g00i => c16(0),
              g01r => c16(0),   g01i => c16(0),
              g10r => c16(0),   g10i => c16(0),
              g11r => c16(ONE), g11i => c16(0));
        case to_integer(unsigned(op)) is
            when 1 =>                                   -- H
                r.g00r := c16(HR);  r.g01r := c16(HR);
                r.g10r := c16(HR);  r.g11r := c16(-HR);
            when 2 =>                                   -- X
                r.g00r := c16(0);   r.g01r := c16(ONE);
                r.g10r := c16(ONE); r.g11r := c16(0);
            when 3 =>                                   -- Y
                r.g00r := c16(0);   r.g01i := c16(-ONE);
                r.g10i := c16(ONE); r.g11r := c16(0);
            when 4 =>                                   -- Z
                r.g11r := c16(-ONE);
            when 5 =>                                   -- S = diag(1, i)
                r.g11r := c16(0);   r.g11i := c16(ONE);
            when 6 =>                                   -- T = diag(1, e^{i pi/4})
                r.g11r := c16(HR);  r.g11i := c16(HR);
            when 7 =>                                   -- RY(theta) = [[c,-s],[s,c]]
                r.g00r := c16(COS_T(k));  r.g01r := c16(-SIN_T(k));
                r.g10r := c16(SIN_T(k));  r.g11r := c16(COS_T(k));
            when 8 =>                                   -- RZ(theta) = diag(c - i s, c + i s)
                r.g00r := c16(COS_T(k));  r.g00i := c16(-SIN_T(k));
                r.g11r := c16(COS_T(k));  r.g11i := c16(SIN_T(k));
            when others =>
                null;
        end case;
        return r;
    end function;

    -- (x + 8192) >>> 14, lalu saturasi ke int16
    function rnd_sat (x : signed(33 downto 0)) return s16 is
        variable t : signed(33 downto 0);
    begin
        t := shift_right(x + 8192, 14);
        if t > 32767 then
            return to_signed(32767, 16);
        elsif t < -32768 then
            return to_signed(-32768, 16);
        else
            return t(15 downto 0);
        end if;
    end function;

    type prod4_t is array (0 to 3) of signed(31 downto 0);

    -- tahap 0
    signal s0_ar, s0_ai, s0_br, s0_bi : s16 := (others => '0');
    signal s0_c : coef_t;
    -- tahap 1
    signal p_ar, p_ai, p_br, p_bi : prod4_t := (others => (others => '0'));
    -- tahap 2
    signal acc_ar, acc_ai, acc_br, acc_bi : signed(33 downto 0) := (others => '0');
    -- tahap 3
    signal o_ar, o_ai, o_br, o_bi : s16 := (others => '0');

    signal v0, v1, v2, v3 : std_logic := '0';

begin

    process (clk)
    begin
        if rising_edge(clk) then
            -- tahap 0 : register operand dan koefisien
            s0_ar <= signed(a_in(31 downto 16));
            s0_ai <= signed(a_in(15 downto 0));
            s0_br <= signed(b_in(31 downto 16));
            s0_bi <= signed(b_in(15 downto 0));
            s0_c  <= coeffs(opcode, param);
            v0    <= valid_in;

            -- tahap 1 : perkalian
            p_ar(0) <= s0_c.g00r * s0_ar;   p_ar(1) <= s0_c.g00i * s0_ai;
            p_ar(2) <= s0_c.g01r * s0_br;   p_ar(3) <= s0_c.g01i * s0_bi;

            p_ai(0) <= s0_c.g00r * s0_ai;   p_ai(1) <= s0_c.g00i * s0_ar;
            p_ai(2) <= s0_c.g01r * s0_bi;   p_ai(3) <= s0_c.g01i * s0_br;

            p_br(0) <= s0_c.g10r * s0_ar;   p_br(1) <= s0_c.g10i * s0_ai;
            p_br(2) <= s0_c.g11r * s0_br;   p_br(3) <= s0_c.g11i * s0_bi;

            p_bi(0) <= s0_c.g10r * s0_ai;   p_bi(1) <= s0_c.g10i * s0_ar;
            p_bi(2) <= s0_c.g11r * s0_bi;   p_bi(3) <= s0_c.g11i * s0_br;
            v1      <= v0;

            -- tahap 2 : jumlahkan (lebar penuh, belum dipotong)
            acc_ar <= resize(p_ar(0), 34) - resize(p_ar(1), 34)
                    + resize(p_ar(2), 34) - resize(p_ar(3), 34);
            acc_ai <= resize(p_ai(0), 34) + resize(p_ai(1), 34)
                    + resize(p_ai(2), 34) + resize(p_ai(3), 34);
            acc_br <= resize(p_br(0), 34) - resize(p_br(1), 34)
                    + resize(p_br(2), 34) - resize(p_br(3), 34);
            acc_bi <= resize(p_bi(0), 34) + resize(p_bi(1), 34)
                    + resize(p_bi(2), 34) + resize(p_bi(3), 34);
            v2     <= v1;

            -- tahap 3 : pembulatan + saturasi
            o_ar <= rnd_sat(acc_ar);
            o_ai <= rnd_sat(acc_ai);
            o_br <= rnd_sat(acc_br);
            o_bi <= rnd_sat(acc_bi);
            v3   <= v2;
        end if;
    end process;

    valid_out <= v3;
    a_out     <= std_logic_vector(o_ar) & std_logic_vector(o_ai);
    b_out     <= std_logic_vector(o_br) & std_logic_vector(o_bi);

end architecture rtl;
