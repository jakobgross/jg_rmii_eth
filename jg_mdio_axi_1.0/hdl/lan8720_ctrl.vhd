----------------------------------------------------------------------------------
-- Engineer     : Jakob Gross
-- Module Name  : lan8720_ctrl
-- Description  : LAN8720 PHY management state machine.
--                Drives jg_mdio_ctrl to bring up the PHY and monitor link state.
--
-- Generics:
--   G_CLK_FREQ_HZ  system clock frequency in Hz
--   G_PHY_ADDR     5-bit PHY SMI address (set by PHYAD0 strap, default 0)
--
-- MDIO controller command interface (connect directly to jg_mdio_ctrl ports):
--   mdio_valid_o / mdio_ready_i
--   mdio_phy_addr_o, mdio_reg_addr_o, mdio_wr_data_o, mdio_wr_en_o
--
-- MDIO controller response interface:
--   mdio_rd_valid_i / mdio_rd_ready_o
--   mdio_rd_data_i
--   mdio_ta_err_i    single-cycle pulse from jg_mdio_ctrl when the PHY does
--                    not drive '0' on the read turnaround bit
--
-- Status outputs:
--   link_up_o        '1' when link is established and auto-negotiation complete
--   speed_o          HCDSPEED from PHY Special Control/Status register bits[4:2]
--                      001 = 10BASE-T  half duplex
--                      101 = 10BASE-T  full duplex
--                      010 = 100BASE-TX half duplex
--                      110 = 100BASE-TX full duplex
--   fault_o          '1' while in FAULT state (transient, clears on retry)
--   phy_id1_o        PHY Identifier 1 (reg 2), latched after READ_ID_1
--   phy_id2_o        PHY Identifier 2 (reg 3), latched after READ_ID_2
--   state_o          4-bit state encoding for PS software readback
--                      0 = POWER_UP_WAIT
--                      1 = READ_ID_1
--                      2 = READ_ID_2
--                      3 = WAIT_LINK
--                      4 = WAIT_AN
--                      5 = READ_SPEED
--                      6 = LINK_UP
--                      7 = FAULT
--
-- Startup sequence:
--   POWER_UP_WAIT (100 ms) -> READ_ID_1 -> READ_ID_2 -> WAIT_LINK
--                                                     -> [TA error] -> FAULT
--   FAULT -> POWER_UP_WAIT  (always retries)
--
--   WAIT_LINK (poll BSR[2]=1) -> WAIT_AN (poll BSR[5]=1)
--                             -> READ_SPEED -> LINK_UP
--
--   LINK_UP polls BSR[2] every 10 ms. On link loss: -> WAIT_LINK.
--   The LAN8720 handles re-negotiation autonomously via MODE=111 straps.
--   No software reset is required.
--
-- MODE[2:0] strap configuration:
--   The LAN8720 latches MODE[2:0] from RXD0/MODE0, RXD1/MODE1, CRS_DV/MODE2
--   at hardware reset. These pins have internal pull-ups (50 uA typical).
--   Since the FPGA treats all three as inputs it never drives them, so the
--   internal pull-ups hold all three high during reset: MODE = 111 = all
--   capable, auto-negotiation enabled. No external resistors are required.
--
-- PHY address:
--   PHYAD0 is multiplexed with the RXER pin. On the Waveshare LAN8720 board
--   RXER/PHYAD0 is pulled high to VCC via an external resistor, so the PHY
--   SMI address is 1. Set G_PHY_ADDR = "00001" when using this board.
--
-- Transaction handshake:
--   txn_sent='0': issue transaction when mdio_ready_i='1', then set txn_sent='1'
--   txn_sent='1': wait for mdio_rd_valid_i, accept with mdio_rd_ready_o='1'
--   ta_err_i may fire before rd_valid_i; latched in ta_err_seen and checked
--   on rd_valid_i. On TA error in any read state: transition to FAULT.
--   txn_sent and ta_err_seen are both cleared on every state transition.
--
-- Revision:
--   0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;
use IEEE.MATH_REAL.all;

entity lan8720_ctrl is
    generic (
        G_CLK_FREQ_HZ : natural                      := 125_000_000;
        G_PHY_ADDR    : std_logic_vector(4 downto 0) := "00001"
    );
    port (
        clk   : in std_logic;
        rst_n : in std_logic;

        -- jg_mdio_ctrl command interface
        mdio_valid_o    : out std_logic;
        mdio_ready_i    : in std_logic;
        mdio_phy_addr_o : out std_logic_vector(4 downto 0);
        mdio_reg_addr_o : out std_logic_vector(4 downto 0);
        mdio_wr_data_o  : out std_logic_vector(15 downto 0);
        mdio_wr_en_o    : out std_logic;

        -- jg_mdio_ctrl response interface
        mdio_rd_valid_i : in std_logic;
        mdio_rd_ready_o : out std_logic;
        mdio_rd_data_i  : in std_logic_vector(15 downto 0);
        mdio_ta_err_i   : in std_logic;

        -- Status outputs
        link_up_o : out std_logic;
        speed_o   : out std_logic_vector(2 downto 0);
        fault_o   : out std_logic;
        state_o   : out std_logic_vector(3 downto 0);
        phy_id1_o : out std_logic_vector(15 downto 0);
        phy_id2_o : out std_logic_vector(15 downto 0);
        debug_o   : out std_logic_vector(31 downto 0)
    );
end entity lan8720_ctrl;

architecture rtl of lan8720_ctrl is

    ---------------------------------------------------------------------------
    -- Timing constants
    ---------------------------------------------------------------------------
    constant C_STARTUP_TICKS : natural := G_CLK_FREQ_HZ / 10;  -- 100 ms
    constant C_POLL_TICKS    : natural := G_CLK_FREQ_HZ / 100; -- 10 ms
    constant C_TIMER_W       : natural := integer(ceil(log2(real(C_STARTUP_TICKS))));

    ---------------------------------------------------------------------------
    -- PHY register addresses (IEEE 802.3 Clause 22)
    ---------------------------------------------------------------------------
    constant C_REG_BSR   : std_logic_vector(4 downto 0) := "00001"; -- reg  1
    constant C_REG_PHY1  : std_logic_vector(4 downto 0) := "00010"; -- reg  2
    constant C_REG_PHY2  : std_logic_vector(4 downto 0) := "00011"; -- reg  3
    constant C_REG_PSCSR : std_logic_vector(4 downto 0) := "11111"; -- reg 31

    ---------------------------------------------------------------------------
    -- State type and encoding (state_o maps 1:1 to integer value below)
    ---------------------------------------------------------------------------
    type t_state is (
        POWER_UP_WAIT, -- 0: wait 100 ms before first MDIO access
        READ_ID_1,     -- 1: read PHY_ID1 register (reg 2)
        READ_ID_2,     -- 2: read PHY_ID2 register (reg 3)
        WAIT_LINK,     -- 3: poll BSR[2] until link is up
        WAIT_AN,       -- 4: poll BSR[5] until auto-negotiation complete
        READ_SPEED,    -- 5: read PSCSR[4:2] for negotiated speed/duplex
        LINK_UP,       -- 6: steady state, poll BSR[2] every 10 ms
        FAULT          -- 7: transient error, retries via POWER_UP_WAIT
    );

    ---------------------------------------------------------------------------
    -- Register type
    ---------------------------------------------------------------------------
    type t_reg is record
        state       : t_state;
        timer       : unsigned(C_TIMER_W - 1 downto 0);
        txn_sent    : std_logic;                     -- '1' while waiting for MDIO response
        ta_err_seen : std_logic;                     -- TA error latched before rd_valid fires
        phy_id1     : std_logic_vector(15 downto 0); -- latched from READ_ID_1
        phy_id2     : std_logic_vector(15 downto 0); -- latched from READ_ID_2
        link_up     : std_logic;
        speed       : std_logic_vector(2 downto 0);
        fault       : std_logic;
    end record;

    constant C_REG_RESET : t_reg := (
        state       => POWER_UP_WAIT,
        timer       => to_unsigned(C_STARTUP_TICKS, C_TIMER_W),
        txn_sent    => '0',
        ta_err_seen => '0',
        phy_id1 => (others => '0'),
        phy_id2 => (others => '0'),
        link_up     => '0',
        speed => (others => '0'),
        fault       => '0'
    );

    signal r   : t_reg;
    signal rin : t_reg;

begin

    ---------------------------------------------------------------------------
    -- Concurrent output assignments
    ---------------------------------------------------------------------------
    link_up_o <= r.link_up;
    speed_o   <= r.speed;
    fault_o   <= r.fault;
    phy_id1_o <= r.phy_id1;
    phy_id2_o <= r.phy_id2;

    debug_o(31 downto C_TIMER_W)    <= (others => '0');
    debug_o(C_TIMER_W - 1 downto 0) <= std_logic_vector(r.timer);

    -- State encoding for PS software readback
    with r.state select state_o <=
    x"0" when POWER_UP_WAIT,
    x"1" when READ_ID_1,
    x"2" when READ_ID_2,
    x"3" when WAIT_LINK,
    x"4" when WAIT_AN,
    x"5" when READ_SPEED,
    x"6" when LINK_UP,
    x"7" when FAULT,
    x"F" when others;

    ---------------------------------------------------------------------------
    -- Combinatorial process
    ---------------------------------------------------------------------------
    comb : process (r, mdio_ready_i, mdio_rd_valid_i, mdio_rd_data_i, mdio_ta_err_i)

        -- Issue a read transaction when the MDIO controller is ready.
        -- Caller must set rin.txn_sent = '1' when mdio_ready_i = '1'.
        procedure issue_read(reg : std_logic_vector(4 downto 0)) is
        begin
            mdio_valid_o    <= mdio_ready_i;
            mdio_wr_en_o    <= '0';
            mdio_phy_addr_o <= G_PHY_ADDR;
            mdio_reg_addr_o <= reg;
            mdio_wr_data_o  <= (others => '0');
        end procedure;

        -- Transition to a new state, resetting per-transaction flags.
        procedure goto(s : t_state) is
        begin
            rin.state       <= s;
            rin.txn_sent    <= '0';
            rin.ta_err_seen <= '0';
        end procedure;

    begin
        rin <= r;

        -- Default: no MDIO transaction
        mdio_valid_o    <= '0';
        mdio_wr_en_o    <= '0';
        mdio_phy_addr_o <= G_PHY_ADDR;
        mdio_reg_addr_o <= (others => '0');
        mdio_wr_data_o  <= (others => '0');
        mdio_rd_ready_o <= '0';

        -- Latch any TA error that arrives while a transaction is in flight
        if mdio_ta_err_i = '1' then
            rin.ta_err_seen <= '1';
        end if;

        case r.state is

                -- Wait 100 ms before the first MDIO access to ensure the PHY
                -- is responsive after power-on or reset.
            when POWER_UP_WAIT =>
                rin.fault <= '0';
                if r.timer = 0 then
                    goto(READ_ID_1);
                else
                    rin.timer <= r.timer - 1;
                end if;

            when READ_ID_1 =>
                if r.txn_sent = '0' then
                    issue_read(C_REG_PHY1);
                    if mdio_ready_i = '1' then
                        rin.txn_sent <= '1';
                    end if;
                else
                    mdio_rd_ready_o <= mdio_rd_valid_i;
                    if mdio_rd_valid_i = '1' then
                        if r.ta_err_seen = '1' or mdio_ta_err_i = '1' then
                            rin.fault <= '1';
                            goto(FAULT);
                        else
                            rin.phy_id1 <= mdio_rd_data_i;
                            goto(READ_ID_2);
                        end if;
                    end if;
                end if;

            when READ_ID_2 =>
                if r.txn_sent = '0' then
                    issue_read(C_REG_PHY2);
                    if mdio_ready_i = '1' then
                        rin.txn_sent <= '1';
                    end if;
                else
                    mdio_rd_ready_o <= mdio_rd_valid_i;
                    if mdio_rd_valid_i = '1' then
                        if r.ta_err_seen = '1' or mdio_ta_err_i = '1' then
                            rin.fault <= '1';
                            goto(FAULT);
                        else
                            rin.phy_id2 <= mdio_rd_data_i;
                            goto(WAIT_LINK);
                        end if;
                    end if;
                end if;

                -- Poll BSR[2] (Link Status) until the PHY reports link up.
                -- BSR[2] is a latch-low bit: it reads '0' if link was ever lost
                -- since the last read, regardless of current state. A single '1'
                -- read confirms stable link.
            when WAIT_LINK =>
                if r.txn_sent = '0' then
                    issue_read(C_REG_BSR);
                    if mdio_ready_i = '1' then
                        rin.txn_sent <= '1';
                    end if;
                else
                    mdio_rd_ready_o <= mdio_rd_valid_i;
                    if mdio_rd_valid_i = '1' then
                        if r.ta_err_seen = '1' or mdio_ta_err_i = '1' then
                            rin.fault <= '1';
                            goto(FAULT);
                        elsif mdio_rd_data_i(2) = '1' then
                            goto(WAIT_AN);
                        else
                            goto(WAIT_LINK);
                        end if;
                    end if;
                end if;

                -- Poll BSR[5] (Auto-Negotiate Complete) until set.
            when WAIT_AN =>
                if r.txn_sent = '0' then
                    issue_read(C_REG_BSR);
                    if mdio_ready_i = '1' then
                        rin.txn_sent <= '1';
                    end if;
                else
                    mdio_rd_ready_o <= mdio_rd_valid_i;
                    if mdio_rd_valid_i = '1' then
                        if r.ta_err_seen = '1' or mdio_ta_err_i = '1' then
                            rin.fault <= '1';
                            goto(FAULT);
                        elsif mdio_rd_data_i(5) = '1' then
                            goto(READ_SPEED);
                        else
                            goto(WAIT_AN);
                        end if;
                    end if;
                end if;

                -- Read PSCSR[4:2] for the negotiated speed and duplex mode.
            when READ_SPEED =>
                if r.txn_sent = '0' then
                    issue_read(C_REG_PSCSR);
                    if mdio_ready_i = '1' then
                        rin.txn_sent <= '1';
                    end if;
                else
                    mdio_rd_ready_o <= mdio_rd_valid_i;
                    if mdio_rd_valid_i = '1' then
                        if r.ta_err_seen = '1' or mdio_ta_err_i = '1' then
                            rin.fault <= '1';
                            goto(FAULT);
                        else
                            rin.speed   <= mdio_rd_data_i(4 downto 2);
                            rin.link_up <= '1';
                            rin.timer   <= to_unsigned(C_POLL_TICKS, C_TIMER_W);
                            goto(LINK_UP);
                        end if;
                    end if;
                end if;

                -- Steady state. Poll BSR[2] every 10 ms.
                -- On link loss: return to WAIT_LINK. The PHY handles re-negotiation
                -- autonomously so no software reset is required.
            when LINK_UP =>
                if r.txn_sent = '0' then
                    if r.timer = 0 then
                        issue_read(C_REG_BSR);
                        if mdio_ready_i = '1' then
                            rin.txn_sent <= '1';
                        end if;
                    else
                        rin.timer <= r.timer - 1;
                    end if;
                else
                    mdio_rd_ready_o <= mdio_rd_valid_i;
                    if mdio_rd_valid_i = '1' then
                        if r.ta_err_seen = '1' or mdio_ta_err_i = '1' then
                            rin.fault   <= '1';
                            rin.link_up <= '0';
                            rin.speed   <= (others => '0');
                            goto(FAULT);
                        elsif mdio_rd_data_i(2) = '0' then
                            -- Link lost; wait for PHY to re-negotiate
                            rin.link_up <= '0';
                            rin.speed   <= (others => '0');
                            goto(WAIT_LINK);
                        else
                            -- Link still up; reset poll timer
                            rin.timer <= to_unsigned(C_POLL_TICKS, C_TIMER_W);
                            goto(LINK_UP);
                        end if;
                    end if;
                end if;

                -- Transient error state. Immediately retry from POWER_UP_WAIT.
            when FAULT =>
                rin.timer <= to_unsigned(C_STARTUP_TICKS, C_TIMER_W);
                goto(POWER_UP_WAIT);

        end case;

    end process comb;

    ---------------------------------------------------------------------------
    -- Sequential process
    ---------------------------------------------------------------------------
    seq : process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                r <= C_REG_RESET;
            else
                r <= rin;
            end if;
        end if;
    end process seq;

end architecture rtl;