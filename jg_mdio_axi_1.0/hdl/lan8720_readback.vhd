----------------------------------------------------------------------------------
-- Engineer     : Jakob Gross
-- Module Name  : lan8720_readback
-- Description  : Continuously reads key LAN8720 PHY registers over MDIO and
--                latches their raw values onto output ports. No interpretation
--                logic -- purely for bringup visibility.
--
--                Cycles through registers in order:
--                  BCR (reg 0), BSR (reg 1), PHY_ID1 (reg 2),
--                  PHY_ID2 (reg 3), PSCSR (reg 31)
--
--                Each register is read once per cycle with a short gap between
--                reads. The latched outputs hold the last read value and are
--                stable until the next read of that register completes.
--
-- Generics:
--   G_CLK_FREQ_HZ  system clock frequency in Hz
--   G_PHY_ADDR     5-bit PHY SMI address
--
-- Revision:
--   0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

entity lan8720_readback is
    generic (
        G_CLK_FREQ_HZ : natural                      := 125_000_000;
        G_PHY_ADDR    : std_logic_vector(4 downto 0) := "00001"
    );
    port (
        clk   : in std_logic;
        rst_n : in std_logic;

        -- jg_mdio_ctrl command interface
        mdio_valid_o    : out std_logic;
        mdio_ready_i    : in  std_logic;
        mdio_phy_addr_o : out std_logic_vector(4 downto 0);
        mdio_reg_addr_o : out std_logic_vector(4 downto 0);
        mdio_wr_data_o  : out std_logic_vector(15 downto 0);
        mdio_wr_en_o    : out std_logic;

        -- jg_mdio_ctrl response interface
        mdio_rd_valid_i : in  std_logic;
        mdio_rd_ready_o : out std_logic;
        mdio_rd_data_i  : in  std_logic_vector(15 downto 0);
        mdio_ta_err_i   : in  std_logic;

        -- Raw register outputs (latched, stable between reads)
        bcr_o   : out std_logic_vector(15 downto 0);  -- reg  0: Basic Control
        bsr_o   : out std_logic_vector(15 downto 0);  -- reg  1: Basic Status
        id1_o   : out std_logic_vector(15 downto 0);  -- reg  2: PHY Identifier 1
        id2_o   : out std_logic_vector(15 downto 0);  -- reg  3: PHY Identifier 2
        pscsr_o : out std_logic_vector(15 downto 0);  -- reg 31: PHY Special Control/Status
        ta_err_o : out std_logic                       -- '1' if last read had TA error
    );
end entity lan8720_readback;

architecture rtl of lan8720_readback is

    -- Short inter-read gap to avoid hammering the bus
    constant C_GAP_TICKS : natural := G_CLK_FREQ_HZ / 1000;  -- 1 ms
    constant C_GAP_W     : natural := integer(ceil(log2(real(C_GAP_TICKS))));

    constant C_REG_BCR   : std_logic_vector(4 downto 0) := "00000";
    constant C_REG_BSR   : std_logic_vector(4 downto 0) := "00001";
    constant C_REG_PHY1  : std_logic_vector(4 downto 0) := "00010";
    constant C_REG_PHY2  : std_logic_vector(4 downto 0) := "00011";
    constant C_REG_PSCSR : std_logic_vector(4 downto 0) := "11111";

    type t_state is (
        GAP,       -- short wait between reads
        READ_BCR,
        READ_BSR,
        READ_PHY1,
        READ_PHY2,
        READ_PSCSR
    );

    type t_reg is record
        state    : t_state;
        gap      : unsigned(C_GAP_W - 1 downto 0);
        txn_sent : std_logic;
        bcr      : std_logic_vector(15 downto 0);
        bsr      : std_logic_vector(15 downto 0);
        id1      : std_logic_vector(15 downto 0);
        id2      : std_logic_vector(15 downto 0);
        pscsr    : std_logic_vector(15 downto 0);
        ta_err   : std_logic;
    end record;

    constant C_REG_RESET : t_reg := (
        state    => GAP,
        gap      => to_unsigned(C_GAP_TICKS, C_GAP_W),
        txn_sent => '0',
        bcr      => (others => '0'),
        bsr      => (others => '0'),
        id1      => (others => '0'),
        id2      => (others => '0'),
        pscsr    => (others => '0'),
        ta_err   => '0'
    );

    signal r   : t_reg;
    signal rin : t_reg;

begin

    bcr_o    <= r.bcr;
    bsr_o    <= r.bsr;
    id1_o    <= r.id1;
    id2_o    <= r.id2;
    pscsr_o  <= r.pscsr;
    ta_err_o <= r.ta_err;

    comb : process(r, mdio_ready_i, mdio_rd_valid_i, mdio_rd_data_i, mdio_ta_err_i)

        procedure issue_read(reg : std_logic_vector(4 downto 0)) is
        begin
            mdio_valid_o    <= mdio_ready_i;
            mdio_wr_en_o    <= '0';
            mdio_phy_addr_o <= G_PHY_ADDR;
            mdio_reg_addr_o <= reg;
            mdio_wr_data_o  <= (others => '0');
            if mdio_ready_i = '1' then
                rin.ta_err <= '0';
            end if;
        end procedure;

        procedure do_read(
            reg      : std_logic_vector(4 downto 0);
            next_st  : t_state
        ) is
        begin
            if r.txn_sent = '0' then
                issue_read(reg);
                if mdio_ready_i = '1' then
                    rin.txn_sent <= '1';
                end if;
            else
                mdio_rd_ready_o <= mdio_rd_valid_i;
                if mdio_rd_valid_i = '1' then
                    rin.ta_err   <= mdio_ta_err_i or r.ta_err;
                    rin.txn_sent <= '0';
                    rin.state    <= next_st;
                    rin.gap      <= to_unsigned(C_GAP_TICKS, C_GAP_W);
                end if;
            end if;
        end procedure;

    begin
        rin <= r;

        mdio_valid_o    <= '0';
        mdio_wr_en_o    <= '0';
        mdio_phy_addr_o <= G_PHY_ADDR;
        mdio_reg_addr_o <= (others => '0');
        mdio_wr_data_o  <= (others => '0');
        mdio_rd_ready_o <= '0';

        case r.state is

            when GAP =>
                if r.gap = 0 then
                    rin.txn_sent <= '0';
                    rin.state    <= READ_BCR;
                else
                    rin.gap <= r.gap - 1;
                end if;

            when READ_BCR =>
                do_read(C_REG_BCR, READ_BSR);
                if mdio_rd_valid_i = '1' and r.txn_sent = '1' then
                    if mdio_ta_err_i = '0' and r.ta_err = '0' then
                        rin.bcr <= mdio_rd_data_i;
                    end if;
                end if;

            when READ_BSR =>
                do_read(C_REG_BSR, READ_PHY1);
                if mdio_rd_valid_i = '1' and r.txn_sent = '1' then
                    if mdio_ta_err_i = '0' and r.ta_err = '0' then
                        rin.bsr <= mdio_rd_data_i;
                    end if;
                end if;

            when READ_PHY1 =>
                do_read(C_REG_PHY1, READ_PHY2);
                if mdio_rd_valid_i = '1' and r.txn_sent = '1' then
                    if mdio_ta_err_i = '0' and r.ta_err = '0' then
                        rin.id1 <= mdio_rd_data_i;
                    end if;
                end if;

            when READ_PHY2 =>
                do_read(C_REG_PHY2, READ_PSCSR);
                if mdio_rd_valid_i = '1' and r.txn_sent = '1' then
                    if mdio_ta_err_i = '0' and r.ta_err = '0' then
                        rin.id2 <= mdio_rd_data_i;
                    end if;
                end if;

            when READ_PSCSR =>
                do_read(C_REG_PSCSR, GAP);
                if mdio_rd_valid_i = '1' and r.txn_sent = '1' then
                    if mdio_ta_err_i = '0' and r.ta_err = '0' then
                        rin.pscsr <= mdio_rd_data_i;
                    end if;
                end if;

        end case;

    end process comb;

    seq : process(clk)
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