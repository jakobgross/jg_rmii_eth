----------------------------------------------------------------------------------
-- Engineer     : Jakob Gross
-- Module Name  : lan8720_ctrl_tb
-- Description  : Testbench for lan8720_ctrl.
--
-- Uses a tiny G_CLK_FREQ_HZ so the 100ms startup timer and 10ms poll
-- timer complete in a handful of clock cycles rather than millions.
--   G_CLK_FREQ_HZ = 1000 -> startup = 100 ticks, poll = 10 ticks
--
-- Provides a mock jg_mdio_ctrl that accepts commands and returns
-- realistic register values.
--
-- Tests:
--   1. Full startup sequence through to LINK_UP
--   2. Link drop in LINK_UP, re-negotiation back to LINK_UP
--   3. Turnaround error -> FAULT -> retry -> LINK_UP
--
-- Mock register responses:
--   REG_PHY1  (reg 2) : 0x0007
--   REG_PHY2  (reg 3) : 0xC0F0
--   REG_BCR   (reg 0) : 0x0000  (reset already clear)
--   REG_BSR   (reg 1) : 0x002C  (link up, AN complete: bits [5,3,2] set)
--   REG_PSCSR (reg 31): 0x0018  (bits[4:2]=110 = 100BASE-TX full duplex)
--
-- Revision:
--   0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity lan8720_ctrl_tb is
end entity lan8720_ctrl_tb;

architecture sim of lan8720_ctrl_tb is

    constant C_CLK_PERIOD : time    := 8 ns;
    constant C_CLK_FREQ   : natural := 1000;  -- tiny value so timers expire fast

    signal clk   : std_logic := '0';
    signal rst_n : std_logic := '0';

    -- jg_mdio_ctrl command interface
    signal mdio_valid_o    : std_logic;
    signal mdio_ready_i    : std_logic := '1';
    signal mdio_phy_addr_o : std_logic_vector(4 downto 0);
    signal mdio_reg_addr_o : std_logic_vector(4 downto 0);
    signal mdio_wr_data_o  : std_logic_vector(15 downto 0);
    signal mdio_wr_en_o    : std_logic;

    -- jg_mdio_ctrl response interface
    signal mdio_rd_valid_i : std_logic := '0';
    signal mdio_rd_ready_o : std_logic;
    signal mdio_rd_data_i  : std_logic_vector(15 downto 0) := (others => '0');
    signal mdio_ta_err_i   : std_logic := '0';

    -- Status outputs
    signal link_up_o : std_logic;
    signal speed_o   : std_logic_vector(2 downto 0);
    signal fault_o   : std_logic;
    signal state_o   : std_logic_vector(3 downto 0);
    signal phy_id1_o : std_logic_vector(15 downto 0);
    signal phy_id2_o : std_logic_vector(15 downto 0);

    -- Mock control
    signal mock_ta_err  : std_logic := '0';  -- inject TA error on next transaction
    signal mock_bsr_val : std_logic_vector(15 downto 0) := x"002C";  -- BSR response

begin

    i_dut : entity work.lan8720_ctrl
        generic map (
            G_CLK_FREQ_HZ => C_CLK_FREQ,
            G_PHY_ADDR    => "00000"
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            mdio_valid_o    => mdio_valid_o,
            mdio_ready_i    => mdio_ready_i,
            mdio_phy_addr_o => mdio_phy_addr_o,
            mdio_reg_addr_o => mdio_reg_addr_o,
            mdio_wr_data_o  => mdio_wr_data_o,
            mdio_wr_en_o    => mdio_wr_en_o,
            mdio_rd_valid_i => mdio_rd_valid_i,
            mdio_rd_ready_o => mdio_rd_ready_o,
            mdio_rd_data_i  => mdio_rd_data_i,
            mdio_ta_err_i   => mdio_ta_err_i,
            link_up_o       => link_up_o,
            speed_o         => speed_o,
            fault_o         => fault_o,
            state_o         => state_o,
            phy_id1_o       => phy_id1_o,
            phy_id2_o       => phy_id2_o
        );

    p_clk : process
    begin
        clk <= '0'; wait for C_CLK_PERIOD / 2;
        clk <= '1'; wait for C_CLK_PERIOD / 2;
    end process;

    ---------------------------------------------------------------------------
    -- Mock jg_mdio_ctrl
    -- Accepts one transaction per iteration. Responds with a realistic
    -- register value after a small latency. Pulses ta_err_i if mock_ta_err='1'.
    ---------------------------------------------------------------------------
    p_mock_mdio : process
        variable reg : std_logic_vector(4 downto 0);
        variable wr  : std_logic;
    begin
        mdio_ready_i    <= '1';
        mdio_rd_valid_i <= '0';
        mdio_rd_data_i  <= (others => '0');
        mdio_ta_err_i   <= '0';

        loop
            -- Wait for DUT to issue a command
            wait until rising_edge(clk) and mdio_valid_o = '1' and mdio_ready_i = '1';
            reg := mdio_reg_addr_o;
            wr  := mdio_wr_en_o;

            -- Simulate MDIO frame latency (a few cycles)
            mdio_ready_i <= '0';
            wait for C_CLK_PERIOD * 5;

            if wr = '1' then
                -- Write: no read response, just return ready
                mdio_ready_i <= '1';
            else
                -- Read: optionally inject TA error then return data
                if mock_ta_err = '1' then
                    mdio_ta_err_i <= '1';
                    wait for C_CLK_PERIOD;
                    mdio_ta_err_i <= '0';
                end if;

                -- Select response based on register address
                case reg is
                    when "00010" => mdio_rd_data_i <= x"0007";  -- PHY_ID1
                    when "00011" => mdio_rd_data_i <= x"C0F0";  -- PHY_ID2
                    when "00001" => mdio_rd_data_i <= mock_bsr_val;  -- BSR
                    when "11111" => mdio_rd_data_i <= x"0018";  -- PSCSR: 100FD
                    when others  => mdio_rd_data_i <= x"FFFF";
                end case;

                mdio_rd_valid_i <= '1';
                wait until rising_edge(clk) and mdio_rd_ready_o = '1';
                mdio_rd_valid_i <= '0';
                mdio_rd_data_i  <= (others => '0');
                mdio_ready_i    <= '1';
            end if;
        end loop;
    end process;

    ---------------------------------------------------------------------------
    -- Stimulus
    ---------------------------------------------------------------------------
    p_stim : process

        procedure wait_state(target : std_logic_vector(3 downto 0)) is
        begin
            wait until rising_edge(clk) and state_o = target;
        end procedure;

        procedure wait_cycles(n : natural) is
        begin
            for i in 0 to n-1 loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

    begin
        wait for C_CLK_PERIOD * 5;
        rst_n <= '1';

        -------------------------------------------------------------------
        -- Test 1: Full startup sequence to LINK_UP
        -------------------------------------------------------------------
        report "Test 1: Full startup sequence";

        wait_state(x"6");  -- LINK_UP
        assert link_up_o = '1'  report "T1: link_up not set"  severity ERROR;
        assert fault_o   = '0'  report "T1: unexpected fault" severity ERROR;
        assert speed_o   = "110" report "T1: speed wrong"     severity ERROR;
        assert phy_id1_o = x"0007" report "T1: phy_id1 wrong" severity ERROR;
        assert phy_id2_o = x"C0F0" report "T1: phy_id2 wrong" severity ERROR;
        report "Test 1: PASS";

        wait_cycles(20);

        -------------------------------------------------------------------
        -- Test 2: Link drop -> re-negotiation -> LINK_UP
        -------------------------------------------------------------------
        report "Test 2: Link drop and re-negotiation";

        -- BSR now reports link down
        mock_bsr_val <= x"0008";  -- bit 2 clear = link down, bit 3 set = AN capable
        wait_state(x"3");  -- WAIT_LINK (link lost, re-negotiating)
        assert link_up_o = '0' report "T2: link_up should be clear" severity ERROR;

        -- Restore BSR to link up
        mock_bsr_val <= x"002C";
        wait_state(x"6");  -- back to LINK_UP
        assert link_up_o = '1' report "T2: link_up not restored" severity ERROR;
        assert fault_o   = '0' report "T2: unexpected fault"     severity ERROR;
        report "Test 2: PASS";

        wait_cycles(20);

        -------------------------------------------------------------------
        -- Test 3: Turnaround error -> FAULT
        -- Reset the DUT and inject a TA error on the first read
        -------------------------------------------------------------------
        report "Test 3: Turnaround error -> FAULT -> retry";

        rst_n       <= '0';
        mock_ta_err <= '1';
        wait_cycles(5);
        rst_n <= '1';

        wait_state(x"7");  -- FAULT
        assert fault_o   = '1' report "T3: fault not set"           severity ERROR;
        assert link_up_o = '0' report "T3: link_up should be clear" severity ERROR;

        -- FAULT transitions immediately to POWER_UP_WAIT for retry
        wait_state(x"0");  -- POWER_UP_WAIT
        assert fault_o = '0' report "T3: fault should clear on retry" severity ERROR;

        -- Allow it to complete the retry with no more TA errors
        mock_ta_err <= '0';
        wait_state(x"6");  -- LINK_UP on retry
        assert link_up_o = '1' report "T3: link_up not set after retry" severity ERROR;
        report "Test 3: PASS";

        report "All tests passed";
        wait;
    end process;

end architecture sim;