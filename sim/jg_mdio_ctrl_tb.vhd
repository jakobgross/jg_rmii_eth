----------------------------------------------------------------------------------
-- Engineer     : Jakob Gross
-- Module Name  : jg_mdio_ctrl_tb
-- Description  : Testbench for jg_mdio_ctrl.
--
-- Tests:
--   1. Write transaction: verify PHY receives correct address and data bits
--   2. Read transaction:  verify rd_data_o matches data driven by PHY model
--   3. No-turnaround:     PHY silent on TA[1], verify ta_err_o='1'
--
-- PHY model timing:
--   After detecting mdio_t='0', waits for the first falling_edge(mdc) to align
--   to the DUT's cycle boundary. Each subsequent bit is then processed as a
--   (rising_edge, falling_edge) pair. This guarantees the PHY and DUT agree on
--   which MDC cycle carries which frame bit, regardless of when in the MDC
--   period the transaction starts.
--
--   For read data: PHY drives MDIO after each falling_edge so the data is
--   settled well before the following rising_edge where the DUT samples
--   (via a 2-stage synchronizer). At 1 MHz MDC the half-period is 504 ns;
--   the synchronizer adds 2 x 8 ns = 16 ns, leaving 488 ns of margin.
--
-- Frame bit positions (DUT fall-pulse index, 1-based):
--    1-32  Preamble  all '1'
--   33-34  Start     "01"
--   35-36  Opcode    "10" read, "01" write
--   37-41  PHY addr  MSB first
--   42-46  Reg addr  MSB first
--   47-48  Turnaround
--   49-64  Data      MSB first
--
-- phy_mode selects PHY behaviour:
--   0 = normal read  (PHY drives '0' on TA[1] then drives 16 data bits)
--   1 = write check  (PHY samples and checks received address and data)
--   2 = no-turnaround (PHY stays silent, bus floats high)
--
-- Revision:
--   0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity jg_mdio_ctrl_tb is
end entity jg_mdio_ctrl_tb;

architecture sim of jg_mdio_ctrl_tb is

    constant C_CLK_PERIOD : time    := 8 ns; -- 125 MHz
    constant C_MDC_DIV    : natural := 126;

    constant C_PHY_ADDR : std_logic_vector(4 downto 0)  := "00001";
    constant C_REG_ADDR : std_logic_vector(4 downto 0)  := "00010";
    constant C_WR_DATA  : std_logic_vector(15 downto 0) := x"ABCD";
    constant C_RD_DATA  : std_logic_vector(15 downto 0) := x"C0F0";

    signal clk   : std_logic := '0';
    signal rst_n : std_logic := '0';

    signal valid_i    : std_logic := '0';
    signal ready_o    : std_logic;
    signal phy_addr_i : std_logic_vector(4 downto 0)  := (others => '0');
    signal reg_addr_i : std_logic_vector(4 downto 0)  := (others => '0');
    signal wr_data_i  : std_logic_vector(15 downto 0) := (others => '0');
    signal wr_en_i    : std_logic                     := '0';

    signal rd_valid_o : std_logic;
    signal rd_ready_i : std_logic := '0';
    signal rd_data_o  : std_logic_vector(15 downto 0);
    signal ta_err_o   : std_logic;

    signal mdc    : std_logic;
    signal mdio_o : std_logic;
    signal mdio_i : std_logic;
    signal mdio_t : std_logic;

    signal phy_drive    : std_logic := '1';
    signal phy_drive_en : std_logic := '0';

    -- Selects PHY model behaviour: 0=read, 1=write check, 2=no-turnaround
    signal phy_mode : natural := 0;

begin

    -- Bus: MAC drives when mdio_t='0', PHY drives when phy_drive_en='1', else high
    mdio_i <= mdio_o when mdio_t = '0' else
        phy_drive when phy_drive_en = '1' else
        '1';

    i_dut : entity work.jg_mdio_ctrl
        generic map(
            G_CLK_FREQ_HZ  => 125_000_000,
            G_MDC_FREQ_DIV => C_MDC_DIV
        )
        port map(
            clk        => clk,
            rst_n      => rst_n,
            valid_i    => valid_i,
            ready_o    => ready_o,
            phy_addr_i => phy_addr_i,
            reg_addr_i => reg_addr_i,
            wr_data_i  => wr_data_i,
            wr_en_i    => wr_en_i,
            rd_valid_o => rd_valid_o,
            rd_ready_i => rd_ready_i,
            rd_data_o  => rd_data_o,
            ta_err_o   => ta_err_o,
            mdc        => mdc,
            mdio_o     => mdio_o,
            mdio_i     => mdio_i,
            mdio_t     => mdio_t
        );

    p_clk : process
    begin
        clk <= '0';
        wait for C_CLK_PERIOD / 2;
        clk <= '1';
        wait for C_CLK_PERIOD / 2;
    end process;

    ---------------------------------------------------------------------------
    -- PHY model
    --
    -- Alignment: after detecting mdio_t='0', waits for the first falling edge
    -- of MDC. This is the moment the DUT completes preamble bit 0 and advances
    -- its bit counter to 1. All subsequent bits are processed as (rise, fall)
    -- pairs, keeping PHY and DUT in lock-step for the rest of the frame.
    ---------------------------------------------------------------------------
    p_phy : process
        variable opcode            : std_logic_vector(1 downto 0);
        variable captured_phy_addr : std_logic_vector(4 downto 0);
        variable captured_reg_addr : std_logic_vector(4 downto 0);
        variable captured_wr_data  : std_logic_vector(15 downto 0);
        variable bit_val           : std_logic;
    begin
        phy_drive    <= '1';
        phy_drive_en <= '0';

        loop
            -- Wait for start of transaction
            wait until falling_edge(ready_o);

            -- Align to the DUT's cycle boundary.
            -- The first falling edge here is when the DUT completes preamble
            -- bit 0 (mdc_fall_p fires, bit_cnt goes 0->1). From this point
            -- every (rise, fall) pair corresponds to one DUT bit counter step.
            wait until falling_edge(mdc);

            -- Preamble bits 1-31 (bit 0 consumed by alignment above)
            for i in 1 to 31 loop
                wait until rising_edge(mdc);
                assert mdio_o = '1'
                report "Preamble bit " & integer'image(i) & " not '1'"
                    severity FAILURE;
                wait until falling_edge(mdc);
            end loop;

            -- Start of frame: bit 0 = '0', bit 1 = '1'
            wait until rising_edge(mdc);
            assert mdio_o = '0' report "START[0]: expected '0'" severity FAILURE;
            wait until falling_edge(mdc);
            wait until rising_edge(mdc);
            assert mdio_o = '1' report "START[1]: expected '1'" severity FAILURE;
            wait until falling_edge(mdc);

            -- Opcode: 2 bits MSB first
            wait until rising_edge(mdc);
            opcode(1) := mdio_o;
            wait until falling_edge(mdc);
            wait until rising_edge(mdc);
            opcode(0) := mdio_o;
            wait until falling_edge(mdc);

            -- PHY address: 5 bits MSB first
            for i in 4 downto 0 loop
                wait until rising_edge(mdc);
                captured_phy_addr(i) := mdio_o;
                wait until falling_edge(mdc);
            end loop;
            assert captured_phy_addr = C_PHY_ADDR
            report "PHY_ADDR mismatch" severity FAILURE;

            -- Register address: 5 bits MSB first
            for i in 4 downto 0 loop
                wait until rising_edge(mdc);
                captured_reg_addr(i) := mdio_o;
                wait until falling_edge(mdc);
            end loop;
            assert captured_reg_addr = C_REG_ADDR
            report "REG_ADDR mismatch" severity FAILURE;

            if opcode = "01" then
                -----------------------------------------------------------
                -- Write transaction
                -----------------------------------------------------------
                assert phy_mode = 1
                report "Unexpected write transaction" severity FAILURE;

                -- Turnaround: MAC drives "10"
                wait until rising_edge(mdc);
                assert mdio_o = '1' report "Write TA[0]: expected '1'" severity FAILURE;
                wait until falling_edge(mdc);
                wait until rising_edge(mdc);
                assert mdio_o = '0' report "Write TA[1]: expected '0'" severity FAILURE;
                wait until falling_edge(mdc);

                -- Capture 16 data bits MSB first
                for i in 15 downto 0 loop
                    wait until rising_edge(mdc);
                    captured_wr_data(i) := mdio_o;
                    wait until falling_edge(mdc);
                end loop;
                assert captured_wr_data = C_WR_DATA
                report "Write data mismatch" severity FAILURE;

            elsif opcode = "10" then
                -----------------------------------------------------------
                -- Read transaction
                -----------------------------------------------------------

                -- TA[0]: MAC tristates, bus idles high; PHY stays silent
                wait until rising_edge(mdc);
                wait until falling_edge(mdc);

                if phy_mode = 2 then
                    -- No-turnaround: PHY stays silent for TA[1] and data.
                    -- Bus stays high throughout; ta_err_o should pulse.
                    for i in 0 to 16 loop
                        wait until rising_edge(mdc);
                        wait until falling_edge(mdc);
                    end loop;

                else
                    -- Normal read: PHY drives '0' on TA[1].
                    -- Drive AFTER the falling edge so the value is stable
                    -- well before the following rising edge where the DUT
                    -- samples (via the 2-stage synchronizer).
                    phy_drive    <= '0';
                    phy_drive_en <= '1';
                    wait until rising_edge(mdc); -- DUT samples TA[1]
                    wait until falling_edge(mdc);

                    -- Drive 16 data bits MSB first
                    for i in 15 downto 0 loop
                        phy_drive <= C_RD_DATA(i);
                        wait until rising_edge(mdc); -- DUT samples bit i
                        wait until falling_edge(mdc);
                    end loop;

                    phy_drive_en <= '0';
                    phy_drive    <= '1';
                end if;

            else
                report "PHY model: unknown opcode" severity FAILURE;
            end if;

        end loop;
    end process;

    ---------------------------------------------------------------------------
    -- Stimulus
    ---------------------------------------------------------------------------
    p_stim : process

        procedure send_cmd (
            phy  : std_logic_vector(4 downto 0);
            reg  : std_logic_vector(4 downto 0);
            data : std_logic_vector(15 downto 0);
            wr   : std_logic
        ) is
        begin
            wait until rising_edge(clk) and ready_o = '1';
            phy_addr_i <= phy;
            reg_addr_i <= reg;
            wr_data_i  <= data;
            wr_en_i    <= wr;
            valid_i    <= '1';
            wait until rising_edge(clk);
            valid_i <= '0';
        end procedure;

    begin
        wait for C_CLK_PERIOD * 10;
        rst_n <= '1';
        wait for C_CLK_PERIOD * 5;

        -------------------------------------------------------------------
        -- Test 1: Write
        -------------------------------------------------------------------
        report "Test 1: Write transaction";
        phy_mode <= 1;
        send_cmd(C_PHY_ADDR, C_REG_ADDR, C_WR_DATA, '1');
        wait until ready_o = '1';
        wait for C_CLK_PERIOD * 10;
        report "Test 1: PASS";

        -------------------------------------------------------------------
        -- Test 2: Read
        -------------------------------------------------------------------
        report "Test 2: Read transaction";
        phy_mode <= 0;
        send_cmd(C_PHY_ADDR, C_REG_ADDR, x"0000", '0');
        wait until rd_valid_o = '1';
        assert rd_data_o = C_RD_DATA
        report "Test 2: rd_data_o mismatch, got 0x" &
            integer'image(to_integer(unsigned(rd_data_o)))
            severity FAILURE;
        rd_ready_i <= '1';
        wait until rising_edge(clk);
        rd_ready_i <= '0';
        wait for C_CLK_PERIOD * 10;
        report "Test 2: PASS";

        -------------------------------------------------------------------
        -- Test 3: No-turnaround (PHY absent)
        -------------------------------------------------------------------
        report "Test 3: No-turnaround error";
        phy_mode <= 2;
        send_cmd(C_PHY_ADDR, C_REG_ADDR, x"0000", '0');
        wait until ta_err_o = '1';
        -- DUT still completes the transaction; accept the (invalid) result
        wait until rd_valid_o = '1';
        rd_ready_i <= '1';
        wait until rising_edge(clk);
        rd_ready_i <= '0';
        wait for C_CLK_PERIOD * 10;
        report "Test 3: PASS";

        report "All tests passed";
        std.env.finish;
    end process;

end architecture sim;