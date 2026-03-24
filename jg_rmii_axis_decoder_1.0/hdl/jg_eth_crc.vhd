----------------------------------------------------------------------------------
-- Engineer     : Jakob Gross
-- Module Name  : jg_eth_crc
-- Description  : Ethernet CRC-32 checker and FCS stripper.
--                Accepts a byte stream from jg_rmii_to_bytes and outputs the
--                frame payload with FCS removed. user_o is set on the last
--                byte if the CRC check fails, matching AXI-Stream TUSER
--                semantics from PG138.
--
-- CRC-32:
--   Polynomial 0xEDB88320 (reflected IEEE 802.3), init 0xFFFFFFFF.
--   Computed over all received bytes including the 4 FCS bytes.
--   Valid residue after a good frame: 0xDEBB20E3.
--   On sof_i the accumulator resets before including the first byte.
--   On eof_i v_crc already includes the last byte and is compared to the
--   residue in the same cycle.
--
-- FCS stripping:
--   A 4-byte shift register holds back the last 4 bytes. Once full, the
--   oldest byte is forwarded each cycle. At EOF the 4 bytes remaining in
--   the buffer are the FCS and are silently discarded.
--
-- Revision:
--   0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity jg_eth_crc is
    port (
        clk   : in std_logic;
        rst_n : in std_logic;

        byte_i       : in std_logic_vector(7 downto 0);
        byte_valid_i : in std_logic;
        sof_i        : in std_logic;
        eof_i        : in std_logic;

        byte_o       : out std_logic_vector(7 downto 0);
        byte_valid_o : out std_logic;
        tlast_o      : out std_logic;
        user_o       : out std_logic
    );
end entity jg_eth_crc;

architecture rtl of jg_eth_crc is

    constant C_CRC_INIT    : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    constant C_CRC_RESIDUE : std_logic_vector(31 downto 0) := x"DEBB20E3";

    type t_fcs_buf is array(0 to 3) of std_logic_vector(7 downto 0);

    type t_reg is record
        crc        : std_logic_vector(31 downto 0);
        fcs_buf    : t_fcs_buf;
        fcs_cnt    : unsigned(2 downto 0);
        byte_out   : std_logic_vector(7 downto 0);
        byte_valid : std_logic;
        tlast      : std_logic;
        user       : std_logic;
    end record;

    constant C_REG_RESET : t_reg := (
        crc        => C_CRC_INIT,
        fcs_buf => (others => (others => '0')),
        fcs_cnt => (others => '0'),
        byte_out => (others => '0'),
        byte_valid => '0',
        tlast      => '0',
        user       => '0'
    );

    signal r   : t_reg;
    signal rin : t_reg;

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
begin

    byte_o       <= r.byte_out;
    byte_valid_o <= r.byte_valid;
    tlast_o      <= r.tlast;
    user_o       <= r.user;

    comb : process (r, byte_i, byte_valid_i, sof_i, eof_i)
        variable v_crc : std_logic_vector(31 downto 0);
    begin
        rin <= r;

        rin.byte_valid <= '0';
        rin.tlast      <= '0';
        rin.user       <= '0';

        v_crc := r.crc;

        if byte_valid_i = '1' then
            if sof_i = '1' then
                v_crc := f_crc32(C_CRC_INIT, byte_i);
                rin.fcs_buf    <= (others => (others => '0'));
                rin.fcs_cnt    <= to_unsigned(1, 3);
                rin.fcs_buf(0) <= byte_i;
            else
                v_crc := f_crc32(v_crc, byte_i);
                rin.fcs_buf(0) <= byte_i;
                rin.fcs_buf(1) <= r.fcs_buf(0);
                rin.fcs_buf(2) <= r.fcs_buf(1);
                rin.fcs_buf(3) <= r.fcs_buf(2);
                if r.fcs_cnt < 4 then
                    rin.fcs_cnt <= r.fcs_cnt + 1;
                end if;
            end if;
            rin.crc <= v_crc;

            -- Normal data path: forward oldest byte when buffer is full
            if r.fcs_cnt >= 4 then
                rin.byte_out   <= r.fcs_buf(3);
                rin.byte_valid <= '1';
            end if;

            -- EOF overrides: set tlast and check CRC
            if eof_i = '1' then
                rin.tlast   <= '1';
                rin.fcs_cnt <= (others => '0');
                rin.crc     <= C_CRC_INIT;

                if r.fcs_cnt < 4 then
                    -- Frame too short: inject error beat
                    rin.byte_out   <= (others => '0');
                    rin.byte_valid <= '1';
                    rin.user       <= '1';
                else
                    if v_crc /= C_CRC_RESIDUE then
                        -- CRC error: inject error beat
                        rin.byte_out   <= (others => '0');
                        rin.byte_valid <= '1';
                        rin.user       <= '1';
                    else
                        -- Good frame: last payload byte already set above
                        rin.user <= '0';
                    end if;
                end if;
            end if;
        end if;

    end process comb;

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