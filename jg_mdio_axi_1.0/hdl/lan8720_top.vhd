----------------------------------------------------------------------------------
-- Engineer     : Jakob Gross
-- Module Name  : lan8720_top
-- Description  : Top-level wrapper for LAN8720 PHY management.
--                Instantiates jg_mdio_ctrl, lan8720_readback, and the Xilinx
--                IOBUF primitive for the bidirectional MDIO pin.
--
--                lan8720_readback is used during bringup to dump raw PHY
--                register values. Replace with lan8720_ctrl for normal operation.
--
-- Generics:
--   G_CLK_FREQ_HZ   system clock frequency in Hz
--   G_MDC_FREQ_DIV  MDC = CLK / G_MDC_FREQ_DIV, must be even, max 2.5 MHz
--   G_PHY_ADDR      5-bit PHY SMI address (Waveshare LAN8720: "00001")
--
-- Ports:
--   clk / rst_n     system clock and active-low synchronous reset
--   mdc             MDIO clock output to LAN8720
--   mdio            bidirectional MDIO data pin (connect directly to PMOD)
--   regs_lo_o       CH1 32-bit: { bsr(15:0), bcr(15:0) }  → AXI GPIO 0x41210000 + 0x000
--   regs_hi_o       CH2 32-bit: { id2(15:0), id1(15:0) }  → AXI GPIO 0x41210000 + 0x008
--   ta_err_o        '1' if last read cycle had a turnaround error
--
-- Debug outputs (remove after bringup):
--   mdio_o_debug_o / mdio_i_debug_o / mdio_t_debug_o  raw IOBUF signals for ILA
--   debug_o         32-bit: { bsr(15:0), bcr(15:0) } for quick ILA readout
--
-- IOBUF wiring:
--   IOBUF.I  <= mdio_o  (MAC drives)
--   IOBUF.T  <= mdio_t  ('1' = high-Z, '0' = drive)
--   IOBUF.O  => mdio_i  (PHY drives)
--   IOBUF.IO <> mdio    (physical PMOD pin)
--
-- Revision:
--   0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library UNISIM;
use UNISIM.VComponents.ALL;

entity lan8720_top is
    generic (
        G_CLK_FREQ_HZ  : natural                      := 125_000_000;
        G_MDC_FREQ_DIV : natural                      := 126;
        G_PHY_ADDR     : std_logic_vector(4 downto 0) := "00001"
    );
    port (
        clk   : in    std_logic;
        rst_n : in    std_logic;

        -- MDIO physical pins
        mdc   : out   std_logic;
        mdio  : inout std_logic;

        -- Raw register outputs (two 32-bit channels for dual AXI GPIO at 0x41210000)
        --   regs_lo_o CH1: { bsr(31:16), bcr(15:0) }
        --   regs_hi_o CH2: { id2(31:16), id1(15:0) }
        regs_lo_o : out std_logic_vector(31 downto 0);
        regs_hi_o : out std_logic_vector(31 downto 0);
        ta_err_o  : out std_logic;

        -- Debug outputs for ILA probing (remove after bringup)
        mdio_o_debug_o : out std_logic;
        mdio_i_debug_o : out std_logic;
        mdio_t_debug_o : out std_logic;
        debug_o        : out std_logic_vector(31 downto 0)
    );
end entity lan8720_top;

architecture rtl of lan8720_top is

    -- Internal MDIO signals between IOBUF and jg_mdio_ctrl
    signal mdio_o_s : std_logic;
    signal mdio_i_s : std_logic;
    signal mdio_t_s : std_logic;

    -- Wires between jg_mdio_ctrl and lan8720_readback
    signal mdio_valid_s    : std_logic;
    signal mdio_ready_s    : std_logic;
    signal mdio_phy_addr_s : std_logic_vector(4 downto 0);
    signal mdio_reg_addr_s : std_logic_vector(4 downto 0);
    signal mdio_wr_data_s  : std_logic_vector(15 downto 0);
    signal mdio_wr_en_s    : std_logic;
    signal mdio_rd_valid_s : std_logic;
    signal mdio_rd_ready_s : std_logic;
    signal mdio_rd_data_s  : std_logic_vector(15 downto 0);
    signal mdio_ta_err_s   : std_logic;

    -- Raw register signals from lan8720_readback
    signal bcr_s : std_logic_vector(15 downto 0);
    signal bsr_s : std_logic_vector(15 downto 0);
    signal id1_s : std_logic_vector(15 downto 0);
    signal id2_s : std_logic_vector(15 downto 0);

begin

    -- Debug wiring
    mdio_o_debug_o <= mdio_o_s;
    mdio_i_debug_o <= mdio_i_s;
    mdio_t_debug_o <= mdio_t_s;

    -- Pack raw registers into two 32-bit GPIO channels
    regs_lo_o <= bsr_s & bcr_s;   -- CH1: { bsr, bcr }
    regs_hi_o <= id2_s & id1_s;   -- CH2: { id2, id1 }

    -- Quick ILA view: BCR and BSR side by side
    debug_o <= bsr_s & bcr_s;

    ---------------------------------------------------------------------------
    -- IOBUF: bidirectional MDIO pin
    -- I  : data to drive onto the pin (from jg_mdio_ctrl)
    -- T  : tristate enable, '1' = high-Z, '0' = drive
    -- O  : data received from the pin (to jg_mdio_ctrl)
    -- IO : connects to the physical PMOD pin
    ---------------------------------------------------------------------------
    i_mdio_iobuf : IOBUF
        port map (
            I  => mdio_o_s,
            T  => mdio_t_s,
            O  => mdio_i_s,
            IO => mdio
        );

    ---------------------------------------------------------------------------
    -- Low-level MDIO controller
    ---------------------------------------------------------------------------
    i_mdio_ctrl : entity work.jg_mdio_ctrl
        generic map (
            G_CLK_FREQ_HZ  => G_CLK_FREQ_HZ,
            G_MDC_FREQ_DIV => G_MDC_FREQ_DIV
        )
        port map (
            clk        => clk,
            rst_n      => rst_n,
            valid_i    => mdio_valid_s,
            ready_o    => mdio_ready_s,
            phy_addr_i => mdio_phy_addr_s,
            reg_addr_i => mdio_reg_addr_s,
            wr_data_i  => mdio_wr_data_s,
            wr_en_i    => mdio_wr_en_s,
            rd_valid_o => mdio_rd_valid_s,
            rd_ready_i => mdio_rd_ready_s,
            rd_data_o  => mdio_rd_data_s,
            ta_err_o   => mdio_ta_err_s,
            mdc        => mdc,
            mdio_o     => mdio_o_s,
            mdio_i     => mdio_i_s,
            mdio_t     => mdio_t_s
        );

    ---------------------------------------------------------------------------
    -- PHY register readback (bringup diagnostics)
    ---------------------------------------------------------------------------
    i_readback : entity work.lan8720_readback
        generic map (
            G_CLK_FREQ_HZ => G_CLK_FREQ_HZ,
            G_PHY_ADDR    => G_PHY_ADDR
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            mdio_valid_o    => mdio_valid_s,
            mdio_ready_i    => mdio_ready_s,
            mdio_phy_addr_o => mdio_phy_addr_s,
            mdio_reg_addr_o => mdio_reg_addr_s,
            mdio_wr_data_o  => mdio_wr_data_s,
            mdio_wr_en_o    => mdio_wr_en_s,
            mdio_rd_valid_i => mdio_rd_valid_s,
            mdio_rd_ready_o => mdio_rd_ready_s,
            mdio_rd_data_i  => mdio_rd_data_s,
            mdio_ta_err_i   => mdio_ta_err_s,
            bcr_o           => bcr_s,
            bsr_o           => bsr_s,
            id1_o           => id1_s,
            id2_o           => id2_s,
            pscsr_o         => open,
            ta_err_o        => ta_err_o
        );

end architecture rtl;