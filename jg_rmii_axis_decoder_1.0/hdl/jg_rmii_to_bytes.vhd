----------------------------------------------------------------------------------
-- Engineer     : Jakob Gross
-- Module Name  : jg_rmii_to_bytes
-- Description  : RMII dibit aligner and byte packer. Produces a byte stream
--                from the raw 2-bit RMII input. sof and eof are synchronous
--                to the first and last valid bytes respectively.
--
-- Alignment:
--   Shifts dibits into sreg while CRS_DV=1. Transitions to ACTIVE when sreg
--   equals 0xD5 (SFD). The SFD byte is not forwarded downstream.
--
-- End of frame (LAN8720A section 3.4.1.1):
--   CRS_DV may toggle at end of frame rather than simply going low. The OR
--   of two consecutive CRS_DV samples is used as rx_dv to handle this.
--   eof_o is combinatorial: byte_valid_d AND NOT rx_dv. It goes high on the
--   same cycle the last byte is presented without an additional register.
--
-- Partial bytes:
--   If rx_dv falls mid-byte the partially shifted sreg is emitted zero-padded
--   in the upper bits. The CRC module downstream will flag this as an error.
--
-- No ready input. Downstream must consume one byte every 4 cycles.
--
-- Revision:
--   0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity jg_rmii_to_bytes is
    port (
        clk   : in std_logic;
        rst_n : in std_logic;

        rmii_crs_dv : in std_logic;
        rmii_rxd    : in std_logic_vector(1 downto 0);

        byte_o       : out std_logic_vector(7 downto 0);
        byte_valid_o : out std_logic;
        sof_o        : out std_logic;
        eof_o        : out std_logic
    );
end entity jg_rmii_to_bytes;

architecture rtl of jg_rmii_to_bytes is

    type t_state is (IDLE, ACTIVE);

    type t_reg is record
        state        : t_state;
        crs_dv_prev  : std_logic;
        sreg         : std_logic_vector(7 downto 0);
        dcnt         : unsigned(1 downto 0);
        first_byte   : std_logic;
        byte_d       : std_logic_vector(7 downto 0);
        byte_valid_d : std_logic;
        sof_d        : std_logic;
    end record;

    constant C_REG_RESET : t_reg := (
        state        => IDLE,
        crs_dv_prev  => '0',
        sreg => (others => '0'),
        dcnt => (others => '0'),
        first_byte   => '0',
        byte_d => (others => '0'),
        byte_valid_d => '0',
        sof_d        => '0'
    );

    signal r   : t_reg;
    signal rin : t_reg;

begin

    byte_o       <= r.byte_d;
    byte_valid_o <= r.byte_valid_d;
    sof_o        <= r.sof_d;
    eof_o        <= r.byte_valid_d and not (rmii_crs_dv or r.crs_dv_prev);

    comb : process (r, rmii_crs_dv, rmii_rxd)
    begin
        rin <= r;

        rin.byte_valid_d <= '0';
        rin.sof_d        <= '0';
        rin.crs_dv_prev  <= rmii_crs_dv;

        case r.state is

            when IDLE           =>
                rin.dcnt <= (others => '0');

                if rmii_crs_dv = '0' then
                    rin.sreg <= (others => '0');
                else
                    rin.sreg <= rmii_rxd & r.sreg(7 downto 2);

                    if (rmii_rxd & r.sreg(7 downto 2)) = x"D5" then
                        rin.state      <= ACTIVE;
                        rin.first_byte <= '1';
                        rin.dcnt       <= (others => '0');
                        rin.sreg       <= (others => '0');
                    end if;
                end if;

            when ACTIVE =>
                if (rmii_crs_dv or r.crs_dv_prev) = '0' then
                    -- rx_dv gone low. Only emit a partial byte if we were
                    -- mid-byte (dcnt > 0). On a byte boundary dcnt=0 means
                    -- no dibits have been shifted in yet so nothing to emit.
                    if r.dcnt /= "00" then
                        -- sreg keeps the received dibits left-aligned.
                        -- Re-pack the valid dibits into the low bits and
                        -- leave the missing MSBs zero-padded.
                        case r.dcnt is
                            when "01"   => rin.byte_d <= "000000" & r.sreg(7 downto 6);
                            when "10"   => rin.byte_d <= "0000" & r.sreg(7 downto 4);
                            when "11"   => rin.byte_d <= "00" & r.sreg(7 downto 2);
                            when others => null;
                        end case;
                        rin.byte_valid_d <= '1';
                    end if;
                    rin.state      <= IDLE;
                    rin.first_byte <= '0';
                    rin.sreg       <= (others => '0');
                    rin.dcnt       <= (others => '0');
                else
                    rin.sreg <= rmii_rxd & r.sreg(7 downto 2);
                    rin.dcnt <= r.dcnt + 1;

                    if r.dcnt = "11" then
                        rin.byte_d       <= rmii_rxd & r.sreg(7 downto 2);
                        rin.byte_valid_d <= '1';
                        rin.sof_d        <= r.first_byte;
                        rin.first_byte   <= '0';
                    end if;
                end if;

        end case;
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