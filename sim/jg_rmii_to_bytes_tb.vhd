----------------------------------------------------------------------------------
-- Engineer     : Jakob Gross
-- Module Name  : jg_rmii_to_bytes_tb
-- Description  : Testbench for jg_rmii_to_bytes.
--
-- p_send drives the RMII bus. p_recv monitors the byte output concurrently.
-- The two processes are independent so byte_valid_o pulses are never missed.
--
-- Tests:
--   1. Three data bytes: sof on first, eof on last
--   2. Single byte frame: sof and eof on the same byte
--   3. 0x55 bytes in frame data: SFD detector must not re-trigger mid-frame
--   4. Partial byte: rx_dv falls mid-byte, partial byte emitted with eof
--
-- Revision:
--   0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity jg_rmii_to_bytes_tb is
end entity jg_rmii_to_bytes_tb;

architecture sim of jg_rmii_to_bytes_tb is

    constant C_CLK_PERIOD : time := 20 ns;

    signal clk          : std_logic                    := '0';
    signal rst_n        : std_logic                    := '0';
    signal rmii_crs_dv  : std_logic                    := '0';
    signal rmii_rxd     : std_logic_vector(1 downto 0) := "00";
    signal byte_o       : std_logic_vector(7 downto 0);
    signal byte_valid_o : std_logic;
    signal sof_o        : std_logic;
    signal eof_o        : std_logic;

    -- Shared queue: sender writes expected bytes, receiver checks them
    type t_expected is record
        data : std_logic_vector(7 downto 0);
        sof  : std_logic;
        eof  : std_logic;
    end record;

    type t_exp_array is array(0 to 63) of t_expected;
    shared variable exp_queue  : t_exp_array;
    shared variable exp_wr_ptr : integer := 0;
    shared variable exp_rd_ptr : integer := 0;

    -- Debug signal showing the last expected value popped from the queue
    signal exp_current : t_expected;

    -- Receiver signals sender when all expected bytes have been checked

    function ts return string is
    begin
        return "[@" & time'image(now) & "] ";
    end function;

begin
    i_dut : entity work.jg_rmii_to_bytes
        port map(
            clk          => clk,
            rst_n        => rst_n,
            rmii_crs_dv  => rmii_crs_dv,
            rmii_rxd     => rmii_rxd,
            byte_o       => byte_o,
            byte_valid_o => byte_valid_o,
            sof_o        => sof_o,
            eof_o        => eof_o
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

        procedure send_preamble_sfd is
        begin
            for i in 0 to 6 loop
                send_byte(x"55");
            end loop;
            send_byte(x"D5");
        end procedure;

        procedure deassert_crs is
        begin
            rmii_crs_dv <= '0';
            rmii_rxd    <= "00";
            wait until rising_edge(clk);
        end procedure;

        -- Enqueue an expected byte for the receiver to check
        procedure expect(
            data : std_logic_vector(7 downto 0);
            sof  : std_logic;
            eof  : std_logic
        ) is
        begin
            exp_queue(exp_wr_ptr) := (data => data, sof => sof, eof => eof);
            exp_wr_ptr            := exp_wr_ptr + 1;
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
        rst_n <= '1';
        wait for C_CLK_PERIOD * 5;

        -----------------------------------------------------------------------
        -- Test 1: Three data bytes
        -----------------------------------------------------------------------
        report ts & "Test 1: three data bytes";
        expect(x"AA", '1', '0');
        expect(x"BB", '0', '0');
        expect(x"CC", '0', '1');

        send_preamble_sfd;
        send_byte(x"AA");
        send_byte(x"BB");
        send_byte(x"CC", '0');
        wait_checked;
        report ts & "Test 1: PASS";

        -----------------------------------------------------------------------
        -- Test 2: Single byte frame
        -----------------------------------------------------------------------
        report ts & "Test 2: single byte frame";
        expect(x"42", '1', '1');

        send_preamble_sfd;
        send_byte(x"42", '0');
        wait_checked;
        report ts & "Test 2: PASS";

        -----------------------------------------------------------------------
        -- Test 3: 0x55 bytes in data must not re-trigger SFD detector
        -----------------------------------------------------------------------
        report ts & "Test 3: 0x55 bytes in data";
        expect(x"AA", '1', '0');
        for i in 0 to 6 loop
            expect(x"55", '0', '0');
        end loop;
        expect(x"D5", '0', '0');
        expect(x"CC", '0', '1');

        send_preamble_sfd;
        send_byte(x"AA");
        for i in 0 to 6 loop
            send_byte(x"55");
        end loop;
        send_byte(x"D5");
        send_byte(x"CC", '0');
        wait_checked;
        report ts & "Test 3: PASS";

        -----------------------------------------------------------------------
        -- Test 4: Partial byte (rx_dv falls after 2 dibits)
        -----------------------------------------------------------------------
        report ts & "Test 4: partial byte";
        expect(x"AA", '1', '0');
        -- 2 dibits: "11" then "10" -> sreg = "10" & "11" & (old zeros)
        -- byte_d = "00" & sreg[7:2] = "00" & "101100"[7:2]... let sim verify
        expect(x"46", '0', '1');

        send_preamble_sfd;
        send_byte(x"AA");
        send_dibit("11");
        send_dibit("10", '0');
        wait_checked;
        report ts & "Test 4: PASS";

        -----------------------------------------------------------------------
        -- Test 5: Preamble dibits without CRS_DV, then valid frame
        -- No output expected from the pre-CRS_DV dibits
        -----------------------------------------------------------------------
        report ts & "Test 5: preamble without CRS_DV then valid frame";
        -- Send raw dibits with CRS_DV low (should be ignored)
        wait until rising_edge(clk);
        rmii_crs_dv <= '0';
        for i in 0 to 31 loop
            wait until rising_edge(clk);
            rmii_rxd <= "01"; -- preamble pattern but no CRS_DV
        end loop;

        expect(x"AA", '1', '0');
        expect(x"BB", '0', '1');

        send_preamble_sfd;
        send_byte(x"AA");
        send_byte(x"BB", '0');
        wait_checked;
        report ts & "Test 5: PASS";

        -----------------------------------------------------------------------
        -- Test 6: Back-to-back frames, no gap between them
        -----------------------------------------------------------------------
        report ts & "Test 6: back-to-back frames";
        expect(x"11", '1', '0');
        expect(x"22", '0', '1');
        expect(x"33", '1', '0');
        expect(x"44", '0', '1');

        send_preamble_sfd;
        send_byte(x"11");
        send_byte(x"22", '0');
        deassert_crs; -- second low cycle ensures rx_dv sees two consecutive lows
        -- Immediately start second frame
        send_preamble_sfd;
        send_byte(x"33");
        send_byte(x"44", '0');
        wait_checked;
        report ts & "Test 6: PASS";

        -----------------------------------------------------------------------
        -- Test 7: CRS_DV drops mid-preamble then recovers, only second
        -- preamble + SFD should produce a frame
        -----------------------------------------------------------------------
        report ts & "Test 7: CRS_DV drops mid-preamble";
        expect(x"AB", '1', '1');

        -- First partial preamble: 3 bytes then CRS_DV drops
        for i in 0 to 1 loop
            send_byte(x"55");
        end loop;
        send_byte(x"55", '0');
        deassert_crs;
        wait for C_CLK_PERIOD * 5;

        -- Full valid frame
        send_preamble_sfd;
        send_byte(x"AB", '0');
        wait_checked;
        report ts & "Test 7: PASS";

        -----------------------------------------------------------------------
        -- Test 8: CRS_DV glitch (low for one cycle mid-frame)
        -- Per RMII spec rev 1.2: CRS_DV toggles on nibble boundaries when
        -- carrier drops before FIFO empties. rx_dv = CRS_DV[n] OR CRS_DV[n-1]
        -- so a single-cycle low keeps rx_dv high. The dibit on RXD during the
        -- glitch cycle is still valid and must be accepted.
        -- Frame completes with all bytes intact, no spurious eof.
        -----------------------------------------------------------------------
        report ts & "Test 8: single-cycle CRS_DV glitch mid-frame";
        expect(x"AA", '1', '0');
        expect(x"BB", '0', '0'); -- BB contains the glitch dibit, still valid
        expect(x"CC", '0', '1');

        send_preamble_sfd;
        send_byte(x"AA");
        -- x"BB" = 10111011, send dibits LSB first:
        -- bits[1:0]="11", bits[3:2]="10", bits[5:4]="11", bits[7:6]="10"
        send_dibit("11"); -- bits[1:0]
        send_dibit("10"); -- bits[3:2]
        -- Glitch: CRS_DV low for one cycle on third dibit
        -- rx_dv = CRS_DV[n] OR CRS_DV[n-1] = '0' OR '1' = '1', dibit still accepted
        send_dibit("11", '0'); -- bits[5:4], CRS_DV glitch
        -- Restore CRS_DV for fourth dibit
        send_dibit("10", '1'); -- bits[7:6]
        send_byte(x"CC", '0');
        wait_checked;
        report ts & "Test 8: PASS";

        wait_checked;
        report ts & "All tests passed";
        std.env.finish;
    end process p_send;

    ---------------------------------------------------------------------------
    -- Receiver process: checks every byte_valid_o pulse against the queue
    ---------------------------------------------------------------------------
    p_recv : process
        variable exp : t_expected;
    begin
        wait until rst_n = '1';

        loop
            wait until rising_edge(clk) and byte_valid_o = '1';

            assert exp_rd_ptr < exp_wr_ptr
            report ts & "unexpected byte received: 0x"
                & integer'image(to_integer(unsigned(byte_o)))
                & " sof=" & std_logic'image(sof_o)
                & " eof=" & std_logic'image(eof_o)
                severity FAILURE;

            exp        := exp_queue(exp_rd_ptr);
            exp_rd_ptr := exp_rd_ptr + 1;
            exp_current <= exp;

            assert byte_o = exp.data
            report ts & "byte mismatch at index " & integer'image(exp_rd_ptr - 1)
                & ": got 0x" & integer'image(to_integer(unsigned(byte_o)))
                & " expected 0x" & integer'image(to_integer(unsigned(exp.data)))
                severity FAILURE;

            assert sof_o = exp.sof
            report ts & "sof mismatch at index " & integer'image(exp_rd_ptr - 1)
                & ": got " & std_logic'image(sof_o)
                & " expected " & std_logic'image(exp.sof)
                severity FAILURE;

            assert eof_o = exp.eof
            report ts & "eof mismatch at index " & integer'image(exp_rd_ptr - 1)
                & ": got " & std_logic'image(eof_o)
                & " expected " & std_logic'image(exp.eof)
                severity FAILURE;
        end loop;
    end process p_recv;

end architecture sim;