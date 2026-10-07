-------------------------------------------------------------------------------
-- VS1053 SPI Controller
-------------------------------------------------------------------------------
-- V0.1    05.10.2011  First version
-- V0.2    20.10.2011  Rewritten CPU interface to SPI state machine
-- V0.3    23.07.2013  Removed DREQ polling in STREAM mode, crackling was audible
-------------------------------------------------------------------------------
-- Address 0 -> Data Buffer (write/read)
-- Address 1 -> Command/Status Register (write/read)
--
-- Data Buffer (write/read):
--     bit 7-0 = Stores read/write data
--
-- Command/Status Register (write):
--     bit 7   = XSC
--     bit 6   = XDCS
--     bit 5   = mode      0: SCI/SDI mode; 1: STREAM 32bit (data word + data word)
--     bit 4   = spiclk    0: 1.75MHz; 1: 3.5MHz
--     bit 3-0 = Reserved
--
-- Command/Status Register (read):
--     bit 7   = BUSY      1: busy, transfer in progress; 0: idle
--     bit 6   = DREQ      1: data not requested; 0: data requested
--     bit 5-0 = Reserved
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

entity vs1053 is
    port (
        -- CPU Interface Signals
        RESET   : in  std_logic;
        CLK     : in  std_logic;
        SPICLK  : in  std_logic;
        WR      : in  std_logic;
        ADDR    : in  std_logic;
        DI      : in  std_logic_vector(7 downto 0);
        DO      : out std_logic_vector(7 downto 0);
        CN      : in  std_logic_vector(31 downto 0);

        -- VS1053 Interface Signals
        SO      : in  std_logic;
        SI      : out std_logic;
        SCLK    : out std_logic;
        XDCS    : out std_logic;
        DREQ    : in  std_logic;
        XCS     : out std_logic
    );
end entity vs1053;

architecture rtl of vs1053 is

    -------------------------------------------------------------------------
    -- Internal Signals
    -------------------------------------------------------------------------
    signal state     : std_logic := '0';                        -- State of the SPI transfer state machine
    signal shift_reg : std_logic_vector(31 downto 0);           -- Shift register
    signal start     : std_logic;                               -- Start transmission flag
    signal bit_cnt   : std_logic_vector(4 downto 0);            -- Number of bits transferred
    signal data_reg  : std_logic_vector(7 downto 0);
    signal mode      : std_logic;
    signal bit_so    : std_logic;

begin

    -------------------------------------------------------------------------
    -- CPU Write Process
    -------------------------------------------------------------------------
    process (CLK, RESET, WR, ADDR)
    begin
        if RESET = '1' then
            data_reg <= (others => '0');
            XCS      <= '1';
            XDCS     <= '1';
            mode     <= '0';

        elsif CLK'event and CLK = '1' then
            -- Read CPU bus into internal registers
            if WR = '1' then
                if ADDR = '0' then
                    data_reg <= DI;
                else
                    XCS  <= DI(7);
                    XDCS <= DI(6);
                    mode <= DI(5);
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Provide data for the CPU to read
    -------------------------------------------------------------------------
    DO <= shift_reg(7 downto 0) when ADDR = '0' else start & DREQ & "000000";

    -------------------------------------------------------------------------
    -- Start Flag Generation
    -------------------------------------------------------------------------
    process (CLK, RESET, WR, bit_cnt)
    begin
        if RESET = '1' or bit_cnt = "11001" then
            start <= '0';
        elsif CLK'event and CLK = '1' then
            if WR = '1' and ADDR = '0' then
                start <= '1';
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- SPI Transfer State Machine (SPICLK domain)
    -------------------------------------------------------------------------
    process (SPICLK, RESET, start)
    begin
        if RESET = '1' then
            bit_cnt   <= (others => '0');
            shift_reg <= (others => '0');
            state     <= '0';

        elsif SPICLK'event and SPICLK = '0' then
            case state is

                -- STATE: IDLE
                when '0' =>
                    if mode = '0' and start = '1' then
                        shift_reg(31 downto 24) <= data_reg;
                        state   <= '1';
                        bit_cnt <= "11000";
                    elsif mode = '1' then
                        shift_reg <= CN;
                        state     <= '1';
                        bit_cnt   <= (others => '0');
                    end if;

                -- STATE: TRANSFER
                when '1' =>
                    bit_cnt   <= bit_cnt + 1;
                    shift_reg <= shift_reg(30 downto 0) & bit_so;

                    if bit_cnt = "11111" and mode = '1' then   -- Continuous stream transfer
                        shift_reg <= CN;
                        bit_cnt   <= (others => '0');
                    end if;

                    if bit_cnt = "11111" and mode = '0' then
                        state <= '0';                          -- End of transfer for SCI/SDI mode
                    end if;

                when others => null;
            end case;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- MISO Sampling (SPICLK rising edge)
    -------------------------------------------------------------------------
    process (SPICLK, bit_so)
    begin
        if SPICLK'event and SPICLK = '1' then
            bit_so <= SO;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Output Assignments
    -------------------------------------------------------------------------
    SCLK <= SPICLK when state = '1' else '0';
    SI   <= shift_reg(31);

end architecture rtl;