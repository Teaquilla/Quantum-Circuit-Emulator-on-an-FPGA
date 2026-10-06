-- qstate_ctrl.vhd
-- FSM kontrol: menerima 1 instruksi 16-bit, lalu untuk gerbang 1-qubit mengiterasi semua pasangan
-- indeks (i0, i1) yang hanya berbeda di bit target, membaca dari RAM, memakai gate_engine, dan
-- menulis balik. Gerbang terkontrol (CNOT, CZ, ...) = gerbang biasa + field control: pasangan
-- dilewati bila bit control pada i0 bernilai 0.
--
-- Instruksi: [15:12] opcode  [11:8] target  [7:4] control (F = tanpa)  [3:0] param
--   0 NOP | 1 H | 2 X | 3 Y | 4 Z | 5 S | 6 T | 7 RY | 8 RZ | 9 MEASURE (dicadangkan) | F RESET
-- Operand tidak valid (target/control >= N_QUBITS, control = target) diperlakukan sebagai NOP.
--
-- Handshake: saat busy = '0', pulsakan instr_valid 1 clock. 'done' = pulsa 1 clock di akhir eksekusi.
-- Saat idle, port RAM A mengikuti rd_addr (data muncul di rd_data 1 clock kemudian).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity qstate_ctrl is
    generic (
        N_QUBITS : positive := 4
    );
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;
        -- antarmuka instruksi
        instr_valid   : in  std_logic;
        instr         : in  std_logic_vector(15 downto 0);
        busy          : out std_logic;
        done          : out std_logic;
        rd_addr       : in  unsigned(N_QUBITS - 1 downto 0);
        -- ke qstate_ram
        a_we          : out std_logic;
        a_addr        : out unsigned(N_QUBITS - 1 downto 0);
        a_din         : out std_logic_vector(31 downto 0);
        b_we          : out std_logic;
        b_addr        : out unsigned(N_QUBITS - 1 downto 0);
        b_din         : out std_logic_vector(31 downto 0);
        -- ke gate_engine
        eng_valid_in  : out std_logic;
        eng_opcode    : out std_logic_vector(3 downto 0);
        eng_param     : out std_logic_vector(3 downto 0);
        eng_valid_out : in  std_logic;
        eng_a_out     : in  std_logic_vector(31 downto 0);
        eng_b_out     : in  std_logic_vector(31 downto 0)
    );
end entity qstate_ctrl;

architecture rtl of qstate_ctrl is

    type state_t is (S_IDLE, S_DECODE, S_INIT, S_ISSUE, S_CAPTURE, S_WAIT_ENG, S_NEXT, S_DONE);
    signal state : state_t := S_IDLE;

    signal ir : std_logic_vector(15 downto 0) := (others => '0');
    signal k  : unsigned(N_QUBITS - 1 downto 0) := (others => '0');   -- penghitung pasangan / alamat init

    signal op_i  : integer range 0 to 15;
    signal tgt_i : integer range 0 to 15;
    signal ctl_i : integer range 0 to 15;

    signal i0, i1      : unsigned(N_QUBITS - 1 downto 0);
    signal ctrl_ok     : std_logic;
    signal last_pair   : std_logic;
    signal bad_operand : std_logic;

    -- sisipkan bit '0' pada posisi t: pemetaan k -> i0
    function insert_zero (kk : unsigned(N_QUBITS - 1 downto 0); t : integer)
        return unsigned is
        variable r : unsigned(N_QUBITS - 1 downto 0);
    begin
        for j in 0 to N_QUBITS - 1 loop
            if j < t then
                r(j) := kk(j);
            elsif j = t then
                r(j) := '0';
            else
                r(j) := kk(j - 1);
            end if;
        end loop;
        return r;
    end function;

begin

    op_i  <= to_integer(unsigned(ir(15 downto 12)));
    tgt_i <= to_integer(unsigned(ir(11 downto 8)));
    ctl_i <= to_integer(unsigned(ir(7 downto 4)));

    i0 <= insert_zero(k, tgt_i);

    process (i0, tgt_i)
        variable v : unsigned(N_QUBITS - 1 downto 0);
    begin
        v := i0;
        if tgt_i < N_QUBITS then
            v(tgt_i) := '1';
        end if;
        i1 <= v;
    end process;

    process (i0, ctl_i)
    begin
        if ctl_i = 15 then
            ctrl_ok <= '1';
        elsif ctl_i < N_QUBITS then
            ctrl_ok <= i0(ctl_i);
        else
            ctrl_ok <= '0';
        end if;
    end process;

    last_pair <= '1' when k = to_unsigned(2 ** (N_QUBITS - 1) - 1, N_QUBITS) else '0';

    bad_operand <= '1' when (tgt_i >= N_QUBITS) or
                            (ctl_i /= 15 and (ctl_i >= N_QUBITS or ctl_i = tgt_i))
                   else '0';

    -- ---------------------------------------------------------------- FSM
    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= S_IDLE;
                k     <= (others => '0');
                ir    <= (others => '0');
            else
                case state is

                    when S_IDLE =>
                        if instr_valid = '1' then
                            ir    <= instr;
                            state <= S_DECODE;
                        end if;

                    when S_DECODE =>
                        k <= (others => '0');
                        if op_i = 15 then
                            state <= S_INIT;
                        elsif op_i >= 1 and op_i <= 8 then
                            if bad_operand = '1' then
                                state <= S_DONE;
                            else
                                state <= S_ISSUE;
                            end if;
                        else
                            state <= S_DONE;            -- NOP, MEASURE (belum ada), opcode tak dikenal
                        end if;

                    when S_INIT =>                      -- tulis |0...0>
                        if k = to_unsigned(2 ** N_QUBITS - 1, N_QUBITS) then
                            state <= S_DONE;
                        else
                            k <= k + 1;
                        end if;

                    when S_ISSUE =>                     -- alamat i0/i1 sudah di port RAM
                        if ctrl_ok = '1' then
                            state <= S_CAPTURE;
                        else
                            state <= S_NEXT;            -- bit control = 0: lewati pasangan ini
                        end if;

                    when S_CAPTURE =>                   -- dout RAM valid, engine mengambilnya
                        state <= S_WAIT_ENG;

                    when S_WAIT_ENG =>                  -- tulis balik terjadi saat eng_valid_out = '1'
                        if eng_valid_out = '1' then
                            state <= S_NEXT;
                        end if;

                    when S_NEXT =>
                        if last_pair = '1' then
                            state <= S_DONE;
                        else
                            k     <= k + 1;
                            state <= S_ISSUE;
                        end if;

                    when S_DONE =>
                        state <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

    -- ------------------------------------------------------------- keluaran
    busy <= '0' when state = S_IDLE else '1';
    done <= '1' when state = S_DONE else '0';

    eng_valid_in <= '1' when state = S_CAPTURE else '0';
    eng_opcode   <= ir(15 downto 12);
    eng_param    <= ir(3 downto 0);

    process (state, rd_addr, k, i0, i1, eng_valid_out, eng_a_out, eng_b_out)
    begin
        a_we   <= '0';
        b_we   <= '0';
        a_addr <= rd_addr;
        b_addr <= rd_addr;
        a_din  <= (others => '0');
        b_din  <= (others => '0');

        case state is
            when S_INIT =>
                a_addr <= k;
                a_we   <= '1';
                if k = 0 then
                    a_din <= x"7FFF0000";               -- amplitudo 1.0 pada |0...0>
                end if;

            when S_ISSUE | S_CAPTURE | S_WAIT_ENG | S_NEXT =>
                a_addr <= i0;
                b_addr <= i1;
                if state = S_WAIT_ENG and eng_valid_out = '1' then
                    a_we  <= '1';
                    b_we  <= '1';
                    a_din <= eng_a_out;
                    b_din <= eng_b_out;
                end if;

            when others =>
                null;
        end case;
    end process;

end architecture rtl;
