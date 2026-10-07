-------------------------------------------------------------------------------
-- Z-Controller
-------------------------------------------------------------------------------
-- V0.1    05.11.2011  First version
-------------------------------------------------------------------------------
-- Controller port 77h
-- On write:
--     bit 0   = SD-card chip select (0 - inactive, 1 - active)
--     bit 1   = CS signal control
--     bit 2-7 = not used
-- On read:
--     bit 0   = 0 - SD-card absent, 1 - SD-card present
--     bit 1   = 1 - card has Read only switch, 0 - card is not Read only protected
--     bit 2-6 = not used
--     bit 7   = 1 - data transfer completed, 0 - transfer in progress
--
-- Data port 57h
-- Used for both writing and reading data from the SPI controller.
-- When data is written to it, it starts being transmitted over SPI. For this
--     8 clock pulses must be generated on the SDCLK output, data on SDDI input
--     will be transmitted sequentially on the rising edge of the clock signal.
--     The data transfer rate is 125 kHz for the ZC controller.
-- When reading from port 57h, incoming serial data can be obtained. Actually
--     when reading port 57h, data received on the SDIN input is transmitted
--     sequentially on the rising edge of the SDCLK clock signal.
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity zcontroller is
    port (
        RESET   : in  std_logic;
        CLK     : in  std_logic;
        A       : in  std_logic;
        DI      : in  std_logic_vector(7 downto 0);
        DO      : out std_logic_vector(7 downto 0);
        RD      : in  std_logic;
        WR      : in  std_logic;
        SDDET   : in  std_logic;
        SDPROT  : in  std_logic;
        CS_n    : out std_logic;
        SCLK    : out std_logic;
        MOSI    : out std_logic;
        MISO    : in  std_logic
    );
end entity zcontroller;

architecture rtl of zcontroller is

    -------------------------------------------------------------------------
    -- Internal Signals
    -------------------------------------------------------------------------
    signal cnt       : std_logic_vector(3 downto 0);
    signal shift_in  : std_logic_vector(7 downto 0);
    signal shift_out : std_logic_vector(7 downto 0);
    signal cnt_en    : std_logic;
    signal csn       : std_logic;

begin

    -------------------------------------------------------------------------
    -- Chip Select Register (port 77h, bit 1)
    -------------------------------------------------------------------------
    process (RESET, CLK, A, WR, DI)
    begin
        if RESET = '1' then
            csn <= '1';
        elsif (CLK'event and CLK = '1') then
            if (A = '1' and WR = '1') then
                csn <= DI(1);
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Counter Enable Logic
    -------------------------------------------------------------------------
    cnt_en <= not cnt(3) or cnt(2) or cnt(1) or cnt(0);

    -------------------------------------------------------------------------
    -- SPI Bit Counter
    -------------------------------------------------------------------------
    process (CLK, cnt_en, A, RD, WR, SDPROT)
    begin
        if (A = '0' and (WR = '1' or RD = '1')) then
            cnt <= "1110";
        else
            if (CLK'event and CLK = '0') then
                if cnt_en = '1' then
                    cnt <= cnt + 1;
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Shift Out Register (MOSI)
    -------------------------------------------------------------------------
    process (CLK)
    begin
        if (CLK'event and CLK = '0') then
            if (A = '0' and WR = '1') then
                shift_out <= DI;
            else
                if cnt(3) = '0' then
                    shift_out(7 downto 0) <= shift_out(6 downto 0) & '1';
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Shift In Register (MISO)
    -------------------------------------------------------------------------
    process (CLK)
    begin
        if (CLK'event and CLK = '0') then
            if cnt(3) = '0' then
                shift_in <= shift_in(6 downto 0) & MISO;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Output Assignments
    -------------------------------------------------------------------------
    SCLK <= CLK and not cnt(3);
    MOSI <= shift_out(7);
    CS_n <= csn;
    DO   <= cnt(3) & "11111" & SDPROT & '0' when A = '1' else shift_in;

end architecture rtl;