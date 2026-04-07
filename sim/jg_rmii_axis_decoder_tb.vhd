----------------------------------------------------------------------------------
-- Engineer     : Jakob Gross
-- Module Name  : jg_rmii_axis_decoder_tb
-- Description  : Testbench for jg_rmii_axis_decoder.
--
-- p_send drives the RMII bus and enqueues expected AXI-Stream words.
-- p_recv monitors m_axis_tvalid/tready and checks words against the queue.
-- The two processes run concurrently so no words are missed.
--
-- Tests:
--   1. Good frame: correct CRC, tuser=0 on tlast, tkeep correct on last word
--   2. Bad CRC: tuser=1 on tlast
--   3. Back-pressure: words_dropped increments when tready withheld
--
-- Revision:
--   0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity jg_rmii_axis_decoder_tb is
end entity jg_rmii_axis_decoder_tb;

architecture sim of jg_rmii_axis_decoder_tb is

    constant C_CLK_PERIOD : time := 20 ns;

    signal clk           : std_logic                    := '0';
    signal resetn        : std_logic                    := '0';
    signal rmii_crs_dv   : std_logic                    := '0';
    signal rmii_rxd      : std_logic_vector(1 downto 0) := "00";
    signal m_axis_tdata  : std_logic_vector(31 downto 0);
    signal m_axis_tkeep  : std_logic_vector(3 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '1';
    signal m_axis_tlast  : std_logic;
    signal m_axis_tuser  : std_logic;
    signal words_dropped : std_logic_vector(15 downto 0);

    ---------------------------------------------------------------------------
    -- Expected word queue
    ---------------------------------------------------------------------------
    type t_expected is record
        tdata : std_logic_vector(31 downto 0);
        tkeep : std_logic_vector(3 downto 0);
        tlast : std_logic;
        tuser : std_logic;
    end record;

    type t_exp_array is array(0 to 127) of t_expected;
    shared variable exp_queue  : t_exp_array;
    shared variable exp_wr_ptr : integer := 0;
    shared variable exp_rd_ptr : integer := 0;
    shared variable flush_mode : boolean := false;

    signal exp_current            : t_expected;
    attribute keep                : string;
    attribute keep of exp_current : signal is "true";

    ---------------------------------------------------------------------------
    -- CRC-32 (reflected 0xEDB88320) for frame generation
    ---------------------------------------------------------------------------
    function f_crc32(crc : std_logic_vector(31 downto 0);
        data                 : std_logic_vector(7 downto 0))
        return std_logic_vector is
        variable c : std_logic_vector(31 downto 0);
        variable b : std_logic;
    begin
        c := crc;
        for i in 0 to 7 loop
            b := c(0) xor data(i);
            c := '0' & c(31 downto 1);
            if b = '1' then
                c := c xor x"EDB88320";
            end if;
        end loop;
        return c;
    end function;

    type t_frame is array(natural range <>) of std_logic_vector(7 downto 0);

begin

    i_dut : entity work.jg_rmii_axis_decoder
        port map(
            clk             => clk,
            resetn          => resetn,
            rmii_crs_dv     => rmii_crs_dv,
            rmii_rxd        => rmii_rxd,
            m_axis_tdata    => m_axis_tdata,
            m_axis_tkeep    => m_axis_tkeep,
            m_axis_tvalid   => m_axis_tvalid,
            m_axis_tready   => m_axis_tready,
            m_axis_tlast    => m_axis_tlast,
            m_axis_tuser    => m_axis_tuser,
            words_dropped_o => words_dropped
        );

    p_clk : process
    begin
        clk <= '0';
        wait for C_CLK_PERIOD / 2;
        clk <= '1';
        wait for C_CLK_PERIOD / 2;
    end process;

    ---------------------------------------------------------------------------
    -- Sender process
    ---------------------------------------------------------------------------
    p_send : process

        procedure send_dibit(d : std_logic_vector(1 downto 0); crs : std_logic := '1') is
        begin
            rmii_crs_dv <= crs;
            rmii_rxd    <= d;
            wait until rising_edge(clk);
        end procedure;

        procedure send_byte(b : std_logic_vector(7 downto 0); crs_last_dibit : std_logic := '1') is
        begin
            send_dibit(b(1 downto 0));
            send_dibit(b(3 downto 2));
            send_dibit(b(5 downto 4));
            send_dibit(b(7 downto 6), crs_last_dibit);
        end procedure;

        procedure send_frame(data : t_frame;
        corrupt_crc               : boolean                       := false) is
        variable crc              : std_logic_vector(31 downto 0) := x"FFFFFFFF";
        variable fcs              : std_logic_vector(31 downto 0);
        variable fcs_out          : std_logic_vector(31 downto 0);
    begin
        for i in 0 to 6 loop
            send_byte(x"55");
        end loop;
        send_byte(x"D5");
        for i in data'range loop
            crc := f_crc32(crc, data(i));
            send_byte(data(i));
        end loop;
        fcs     := not crc;
        fcs_out := fcs;
        if corrupt_crc then
            fcs_out(7 downto 0) := x"FF";
        end if;
        send_byte(fcs_out(7 downto 0));
        send_byte(fcs_out(15 downto 8));
        send_byte(fcs_out(23 downto 16));
        send_byte(fcs_out(31 downto 24), '0');
    end procedure;

    procedure expect(
        tdata : std_logic_vector(31 downto 0);
        tkeep : std_logic_vector(3 downto 0);
        tlast : std_logic;
        tuser : std_logic
    ) is
    begin
        exp_queue(exp_wr_ptr) := (tdata => tdata, tkeep => tkeep,
        tlast => tlast, tuser => tuser);
        exp_wr_ptr := exp_wr_ptr + 1;
    end procedure;

    procedure send_gap is
    begin
        rmii_crs_dv <= '0';
        rmii_rxd    <= "00";
        wait until rising_edge(clk);
        wait until rising_edge(clk);
    end procedure;

    procedure wait_checked is
    begin
        loop
            wait until rising_edge(clk);
            exit when exp_rd_ptr = exp_wr_ptr;
        end loop;
    end procedure;

begin
    wait for C_CLK_PERIOD * 5;
    resetn <= '1';
    wait for C_CLK_PERIOD * 5;

    -----------------------------------------------------------------------
    -- Test 1: Good frame (14 bytes = DA(6) + SA(6) + EtherType(2))
    -- 14 bytes -> 3 full words (12 bytes) + 1 partial word (2 bytes)
    -- tkeep on last word = "0011"
    -----------------------------------------------------------------------
    report "[@" & time'image(now) & "] Test 1: good frame";
    m_axis_tready <= '1';

    expect(x"DADADADA", "1111", '0', '0'); -- DA[0..3]
    expect(x"BBBBDADA", "1111", '0', '0'); -- DA[4..5] + SA[0..1]
    expect(x"BBBBBBBB", "1111", '0', '0'); -- SA[2..5]
    expect(x"00000008", "0011", '1', '0'); -- EtherType 0x0800 (LSB first)

    send_frame((x"DA", x"DA", x"DA", x"DA", x"DA", x"DA", -- destination MAC
    x"BB", x"BB", x"BB", x"BB", x"BB", x"BB",             -- source MAC
    x"08", x"00"));                                       -- EtherType IPv4
    wait_checked;
    report "[@" & time'image(now) & "] Test 1: PASS";

    -----------------------------------------------------------------------
    -- Test 2: Bad CRC - tuser=1 on last word
    -----------------------------------------------------------------------
    report "[@" & time'image(now) & "] Test 2: bad CRC";
    m_axis_tready <= '1';

    expect(x"DADADADA", "1111", '0', '0');
    expect(x"BBBBDADA", "1111", '0', '0');
    expect(x"BBBBBBBB", "1111", '0', '0');
    expect(x"00000008", "0011", '1', '1'); -- tuser=1 on bad CRC

    send_frame((x"DA", x"DA", x"DA", x"DA", x"DA", x"DA",
    x"BB", x"BB", x"BB", x"BB", x"BB", x"BB",
    x"08", x"00"), corrupt_crc => true);
    wait_checked;
    report "[@" & time'image(now) & "] Test 2: PASS";

    -----------------------------------------------------------------------
    -- Test 3: Back-pressure causes words_dropped to increment.
    -- tready held low during frame transmission, then released.
    -- Words that arrive after tready is released will be caught by p_recv
    -- as unexpected - so we wait long enough for all words to drain first.
    -----------------------------------------------------------------------
    report "[@" & time'image(now) & "] Test 3: back-pressure / words dropped";
    m_axis_tready <= '0';

    send_frame((x"DA", x"DA", x"DA", x"DA", x"DA", x"DA",
    x"BB", x"BB", x"BB", x"BB", x"BB", x"BB",
    x"08", x"00"));

    wait for C_CLK_PERIOD * 500;
    assert unsigned(words_dropped) > 0
    report "[@" & time'image(now) & "] Test 3: expected words_dropped > 0"
        severity FAILURE;

    -- Release tready, flush remaining words silently with a generous wait
    flush_mode := true;
    m_axis_tready <= '1';
    wait for C_CLK_PERIOD * 200;
    flush_mode := false;

    report "[@" & time'image(now) & "] Test 3: PASS  words_dropped="
        & integer'image(to_integer(unsigned(words_dropped)));

    -----------------------------------------------------------------------
    -- Test 4: Stress test - 10 back-to-back good frames after back-pressure
    -----------------------------------------------------------------------
    report "[@" & time'image(now) & "] Test 4: stress test 10 frames";
    m_axis_tready <= '1';

    for i in 0 to 9 loop
        expect(x"DADADADA", "1111", '0', '0');
        expect(x"BBBBDADA", "1111", '0', '0');
        expect(x"BBBBBBBB", "1111", '0', '0');
        expect(x"00000008", "0011", '1', '0');

        send_frame((x"DA", x"DA", x"DA", x"DA", x"DA", x"DA",
        x"BB", x"BB", x"BB", x"BB", x"BB", x"BB",
        x"08", x"00"));
        send_gap;
    end loop;
    wait_checked;
    report "[@" & time'image(now) & "] Test 4: PASS";

    report "[@" & time'image(now) & "] All tests passed";
    std.env.finish;
end process p_send;

---------------------------------------------------------------------------
-- Receiver process: checks every accepted AXI-Stream word against queue
---------------------------------------------------------------------------
p_recv : process
    variable exp : t_expected;
begin
    wait until resetn = '1';

    loop
        wait until rising_edge(clk) and m_axis_tvalid = '1' and m_axis_tready = '1';

        if not flush_mode then
            assert exp_rd_ptr < exp_wr_ptr
            report "[@" & time'image(now) & "] unexpected word received: tdata=0x"
                & integer'image(to_integer(unsigned(m_axis_tdata)))
                & " tlast=" & std_logic'image(m_axis_tlast)
                & " tuser=" & std_logic'image(m_axis_tuser)
                severity FAILURE;

            exp        := exp_queue(exp_rd_ptr);
            exp_rd_ptr := exp_rd_ptr + 1;
            exp_current <= exp;

            assert m_axis_tdata = exp.tdata
            report "[@" & time'image(now) & "] tdata mismatch at index " & integer'image(exp_rd_ptr - 1)
                & ": got 0x" & integer'image(to_integer(unsigned(m_axis_tdata)))
                & " expected 0x" & integer'image(to_integer(unsigned(exp.tdata)))
                severity FAILURE;

            assert m_axis_tkeep = exp.tkeep
            report "[@" & time'image(now) & "] tkeep mismatch at index " & integer'image(exp_rd_ptr - 1)
                & ": got " & integer'image(to_integer(unsigned(m_axis_tkeep)))
                & " expected " & integer'image(to_integer(unsigned(exp.tkeep)))
                severity FAILURE;

            assert m_axis_tlast = exp.tlast
            report "[@" & time'image(now) & "] tlast mismatch at index " & integer'image(exp_rd_ptr - 1)
                & ": got " & std_logic'image(m_axis_tlast)
                & " expected " & std_logic'image(exp.tlast)
                severity FAILURE;

            assert m_axis_tuser = exp.tuser
            report "[@" & time'image(now) & "] tuser mismatch at index " & integer'image(exp_rd_ptr - 1)
                & ": got " & std_logic'image(m_axis_tuser)
                & " expected " & std_logic'image(exp.tuser)
                severity FAILURE;
        end if;
    end loop;
end process p_recv;

end architecture sim;