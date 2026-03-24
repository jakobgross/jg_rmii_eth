----------------------------------------------------------------------------------
-- Engineer     : Jakob Gross
-- Module Name  : jg_mdio_axi
-- Description  : AXI4-Lite slave wrapper around jg_mdio_ctrl.
--
--                AXI address bits [6:2] select the MDIO register (0-31).
--                AXI read  -> MDIO read,  returns data when complete.
--                AXI write -> MDIO write, sends write response when complete.
--
--                AW and W channels are decoupled: each is accepted
--                independently and latched. The MDIO transaction starts
--                only once both have been seen.
--
--                The MDIO transaction stalls the AXI response until complete.
--                ta_err from jg_mdio_ctrl maps to AXI SLVERR (bresp/rresp=10).
--
--                PHY address is fixed via G_PHY_ADDR generic.
--
-- Revision:
--   0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity jg_mdio_axi is
    generic (
        G_CLK_FREQ_HZ      : natural                      := 125_000_000;
        G_MDC_FREQ_DIV     : natural                      := 126;
        G_PHY_ADDR         : std_logic_vector(4 downto 0) := "00001";
        C_S_AXI_DATA_WIDTH : integer                      := 32;
        C_S_AXI_ADDR_WIDTH : integer                      := 7
    );
    port (
        s_axi_aclk    : in  std_logic;
        s_axi_aresetn : in  std_logic;
        s_axi_awaddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        s_axi_awprot  : in  std_logic_vector(2 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;
        s_axi_wdata   : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        s_axi_wstrb   : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;
        s_axi_araddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        s_axi_arprot  : in  std_logic_vector(2 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;
        s_axi_rdata   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;

        -- MDIO pins (connect IOBUF in top level)
        mdc_o    : out std_logic;
        mdio_o_o : out std_logic;
        mdio_i_i : in  std_logic;
        mdio_t_o : out std_logic
    );
end entity jg_mdio_axi;

architecture rtl of jg_mdio_axi is

    type t_state is (IDLE, MDIO_WAIT, WR_RESP, RD_RESP);

    type t_reg is record
        state       : t_state;
        aw_seen     : std_logic;
        w_seen      : std_logic;
        reg_addr    : std_logic_vector(4 downto 0);
        wr_data     : std_logic_vector(15 downto 0);
        is_write    : std_logic;
        ta_err_seen : std_logic;
        mdio_valid  : std_logic;
        -- AXI outputs
        awready     : std_logic;
        wready      : std_logic;
        bvalid      : std_logic;
        bresp       : std_logic_vector(1 downto 0);
        arready     : std_logic;
        rvalid      : std_logic;
        rresp       : std_logic_vector(1 downto 0);
        rdata       : std_logic_vector(31 downto 0);
    end record;

    constant C_REG_RESET : t_reg := (
        state       => IDLE,
        aw_seen     => '0',
        w_seen      => '0',
        reg_addr    => (others => '0'),
        wr_data     => (others => '0'),
        is_write    => '0',
        ta_err_seen => '0',
        mdio_valid  => '0',
        awready     => '0',
        wready      => '0',
        bvalid      => '0',
        bresp       => "00",
        arready     => '0',
        rvalid      => '0',
        rresp       => "00",
        rdata       => (others => '0')
    );

    signal r   : t_reg;
    signal rin : t_reg;

    -- jg_mdio_ctrl outputs
    signal mdio_ready    : std_logic;
    signal mdio_rd_valid : std_logic;
    signal mdio_rd_data  : std_logic_vector(15 downto 0);
    signal mdio_ta_err   : std_logic;

begin

    s_axi_awready <= r.awready;
    s_axi_wready  <= r.wready;
    s_axi_bresp   <= r.bresp;
    s_axi_bvalid  <= r.bvalid;
    s_axi_arready <= r.arready;
    s_axi_rdata   <= r.rdata;
    s_axi_rresp   <= r.rresp;
    s_axi_rvalid  <= r.rvalid;

    ---------------------------------------------------------------------------
    -- Combinatorial process
    ---------------------------------------------------------------------------
    comb : process(r, s_axi_awvalid, s_axi_awaddr, s_axi_wvalid, s_axi_wdata,
                   s_axi_bready, s_axi_arvalid, s_axi_araddr, s_axi_rready,
                   mdio_ready, mdio_rd_valid, mdio_rd_data, mdio_ta_err)
    begin
        rin <= r;

        -- Default pulse outputs to 0 every cycle
        rin.awready <= '0';
        rin.wready  <= '0';
        rin.arready <= '0';

        case r.state is

            when IDLE =>
                rin.mdio_valid  <= '0';
                rin.ta_err_seen <= '0';

                -- Accept AW channel independently
                if s_axi_awvalid = '1' and r.aw_seen = '0' then
                    rin.awready  <= '1';
                    rin.reg_addr <= s_axi_awaddr(6 downto 2);
                    rin.aw_seen  <= '1';
                end if;

                -- Accept W channel independently
                if s_axi_wvalid = '1' and r.w_seen = '0' then
                    rin.wready  <= '1';
                    rin.wr_data <= s_axi_wdata(15 downto 0);
                    rin.w_seen  <= '1';
                end if;

                -- Both channels seen: launch write MDIO transaction
                if (r.aw_seen = '1' or (s_axi_awvalid = '1' and r.aw_seen = '0')) and
                   (r.w_seen  = '1' or (s_axi_wvalid  = '1' and r.w_seen  = '0')) then
                    rin.is_write   <= '1';
                    rin.mdio_valid <= '1';
                    rin.aw_seen    <= '0';
                    rin.w_seen     <= '0';
                    rin.state      <= MDIO_WAIT;

                -- Accept AR channel: launch read MDIO transaction
                -- Only when no write is pending to avoid addr conflict
                elsif s_axi_arvalid = '1' and r.aw_seen = '0' and r.w_seen = '0' then
                    rin.arready    <= '1';
                    rin.reg_addr   <= s_axi_araddr(6 downto 2);
                    rin.is_write   <= '0';
                    rin.mdio_valid <= '1';
                    rin.state      <= MDIO_WAIT;
                end if;

            when MDIO_WAIT =>
                -- Hold VALID high until handshake (READY seen)
                if mdio_ready = '1' then
                    rin.mdio_valid <= '0';
                else
                    rin.mdio_valid <= '1';
                end if;

                -- Latch ta_err if it fires during the transaction
                if mdio_ta_err = '1' then
                    rin.ta_err_seen <= '1';
                end if;

                -- Transaction complete
                if mdio_rd_valid = '1' then
                    if  r.ta_err_seen = '1' then
                        rin.bresp  <= "10";
                    else
                        rin.bresp  <="00";
                    end if;
                    if r.is_write = '1' then
                        rin.bvalid <= '1';
                        rin.state  <= WR_RESP;
                    else
                        rin.rdata  <= x"0000" & mdio_rd_data;
                        rin.rvalid <= '1';
                        rin.state  <= RD_RESP;
                    end if;
                end if;

            when WR_RESP =>
                if s_axi_bready = '1' then
                    rin.bvalid <= '0';
                    rin.state  <= IDLE;
                end if;

            when RD_RESP =>
                if s_axi_rready = '1' then
                    rin.rvalid <= '0';
                    rin.state  <= IDLE;
                end if;

        end case;
    end process comb;

    ---------------------------------------------------------------------------
    -- Sequential process
    ---------------------------------------------------------------------------
    seq : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                r <= C_REG_RESET;
            else
                r <= rin;
            end if;
        end if;
    end process seq;

    ---------------------------------------------------------------------------
    -- jg_mdio_ctrl instantiation
    ---------------------------------------------------------------------------
    i_mdio_ctrl : entity work.jg_mdio_ctrl
        generic map (
            G_CLK_FREQ_HZ  => G_CLK_FREQ_HZ,
            G_MDC_FREQ_DIV => G_MDC_FREQ_DIV
        )
        port map (
            clk        => s_axi_aclk,
            rst_n      => s_axi_aresetn,
            valid_i    => r.mdio_valid,
            ready_o    => mdio_ready,
            phy_addr_i => G_PHY_ADDR,
            reg_addr_i => r.reg_addr,
            wr_data_i  => r.wr_data,
            wr_en_i    => r.is_write,
            rd_valid_o => mdio_rd_valid,
            rd_ready_i => '1',
            rd_data_o  => mdio_rd_data,
            ta_err_o   => mdio_ta_err,
            mdc        => mdc_o,
            mdio_o     => mdio_o_o,
            mdio_i     => mdio_i_i,
            mdio_t     => mdio_t_o
        );

end architecture rtl;