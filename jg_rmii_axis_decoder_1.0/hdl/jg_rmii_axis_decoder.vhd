----------------------------------------------------------------------------------
-- Engineer     : Jakob Gross
-- Module Name  : jg_rmii_axis_decoder
-- Description  : RMII to AXI-Stream decoder. Connects jg_rmii_to_bytes and
--                jg_eth_crc and packs the resulting byte stream into 32-bit
--                AXI-Stream words compatible with PG138 m_axis_rxd.
--
--                Output is a raw Ethernet frame (preamble, SFD and FCS
--                stripped, CRC checked) presented as 32-bit words with TKEEP
--                indicating valid bytes on the final word.
--
-- Word builder:
--                Bytes arrive at 50 MHz one every 4 cycles. Words are
--                assembled and held until tready is asserted. If a new word
--                completes before the previous one is accepted, the frame is
--                dropped and words_dropped_o is incremented.
--
-- Clocked by rmii_ref_clk (50 MHz). CDC to clk_proto via M8.
--
-- Revision:
--   0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity jg_rmii_axis_decoder is
    port (
        clk   : in std_logic; -- rmii_ref_clk, 50 MHz
        resetn : in std_logic;

        rmii_crs_dv : in std_logic;
        rmii_rxd    : in std_logic_vector(1 downto 0);

        -- AXI-Stream output (PG138 m_axis_rxd compatible)
        m_axis_tdata  : out std_logic_vector(31 downto 0);
        m_axis_tkeep  : out std_logic_vector(3 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tuser  : out std_logic;

        -- Saturating count of words dropped due to back-pressure
        words_dropped_o : out std_logic_vector(15 downto 0)
    );
end entity jg_rmii_axis_decoder;

architecture rtl of jg_rmii_axis_decoder is

    -- jg_rmii_to_bytes output
    signal byte_s       : std_logic_vector(7 downto 0);
    signal byte_valid_s : std_logic;
    signal sof_s        : std_logic;
    signal eof_s        : std_logic;

    -- jg_eth_crc output
    signal crc_byte_s  : std_logic_vector(7 downto 0);
    signal crc_valid_s : std_logic;
    signal crc_tlast_s : std_logic;
    signal crc_user_s  : std_logic;

    type t_reg is record
        word          : std_logic_vector(31 downto 0);
        byte_cnt      : unsigned(1 downto 0);
        tvalid        : std_logic;
        tdata         : std_logic_vector(31 downto 0);
        tkeep         : std_logic_vector(3 downto 0);
        tlast         : std_logic;
        tuser         : std_logic;
        words_dropped : unsigned(15 downto 0);
    end record;

    constant C_REG_RESET : t_reg := (
        word => (others => '0'),
        byte_cnt => (others => '0'),
        tvalid => '0',
        tdata => (others => '0'),
        tkeep => (others => '0'),
        tlast  => '0',
        tuser  => '0',
        words_dropped => (others => '0')
    );

    signal r   : t_reg;
    signal rin : t_reg;

begin

    m_axis_tdata    <= r.tdata;
    m_axis_tkeep    <= r.tkeep;
    m_axis_tvalid   <= r.tvalid;
    m_axis_tlast    <= r.tlast;
    m_axis_tuser    <= r.tuser;
    words_dropped_o <= std_logic_vector(r.words_dropped);

    i_rmii_to_bytes : entity work.jg_rmii_to_bytes
        port map(
            clk          => clk,
            rst_n        => resetn,
            rmii_crs_dv  => rmii_crs_dv,
            rmii_rxd     => rmii_rxd,
            byte_o       => byte_s,
            byte_valid_o => byte_valid_s,
            sof_o        => sof_s,
            eof_o        => eof_s
        );

    i_eth_crc : entity work.jg_eth_crc
        port map(
            clk          => clk,
            rst_n        => resetn,
            byte_i       => byte_s,
            byte_valid_i => byte_valid_s,
            sof_i        => sof_s,
            eof_i        => eof_s,
            byte_o       => crc_byte_s,
            byte_valid_o => crc_valid_s,
            tlast_o      => crc_tlast_s,
            user_o       => crc_user_s
        );

    comb : process (r, crc_byte_s, crc_valid_s, crc_tlast_s, crc_user_s, m_axis_tready)
        variable v_word : std_logic_vector(31 downto 0);
    begin
        rin <= r;

        if r.tvalid = '1' and m_axis_tready = '1' then
            rin.tvalid <= '0';
        end if;

        if crc_valid_s = '1' then
            v_word := r.word;
            case to_integer(r.byte_cnt) is
                when 0      => v_word(7 downto 0)   := crc_byte_s;
                when 1      => v_word(15 downto 8)  := crc_byte_s;
                when 2      => v_word(23 downto 16) := crc_byte_s;
                when 3      => v_word(31 downto 24) := crc_byte_s;
                when others => null;
            end case;
            rin.word <= v_word;

            if r.byte_cnt = "11" or crc_tlast_s = '1' then
                -- Word complete or last byte of frame: emit
                if r.tvalid = '1' and m_axis_tready = '0' then
                    -- Previous word not yet accepted: drop and increment counter (wraps)
                    rin.words_dropped <= r.words_dropped + 1;
                end if;
                rin.tdata    <= v_word;
                rin.tkeep    <= std_logic_vector(shift_right(to_unsigned(15, 4), 3 - to_integer(r.byte_cnt)));
                rin.tvalid   <= '1';
                rin.tlast    <= crc_tlast_s;
                rin.tuser    <= crc_user_s;
                rin.word     <= (others => '0');
                rin.byte_cnt <= (others => '0');
            else
                rin.byte_cnt <= r.byte_cnt + 1;
            end if;
        end if;

    end process comb;

    seq : process (clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                r <= C_REG_RESET;
            else
                r <= rin;
            end if;
        end if;
    end process seq;

end architecture rtl;