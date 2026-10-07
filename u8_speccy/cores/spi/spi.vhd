-------------------------------------------------------------------------------
-- SPI Master
-------------------------------------------------------------------------------
-- V0.1.0   31.01.2011  First version
-- V0.2.0   31.08.2013  Rewritten controller. Independent operation from system clock
-- V0.2.1   01.09.2013  Fixed controller
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity spi is
    port (
        RESET   : in  std_logic;                     -- 1 = active reset
        CLK     : in  std_logic;                     -- Controller system clock
        SCK     : in  std_logic;                     -- SPI interface clock
        A       : in  std_logic;                     -- Address: 0 = data register; 1 = control register
        DI      : in  std_logic_vector(7 downto 0);  -- Data 8 bits, input
        DO      : out std_logic_vector(7 downto 0);  -- Data 8 bits, output
        WR      : in  std_logic;                     -- 1 = write data to data or control register
        BUSY    : out std_logic;                     -- 1 = transfer in progress; 0 = completed
        CS_n    : out std_logic;                     -- Chip select (active low)
        SCLK    : out std_logic;                     -- SPI clock output
        MOSI    : out std_logic;                     -- Master Out Slave In
        MISO    : in  std_logic                      -- Master In Slave Out
    );
end entity spi;

architecture rtl of spi is

    -------------------------------------------------------------------------
    -- Internal Signals
    -------------------------------------------------------------------------
    signal cnt        : std_logic_vector(2 downto 0) := "000";       -- Bit counter
    signal shift_reg  : std_logic_vector(7 downto 0) := "11111111";  -- Shift register
    signal cs         : std_logic := '1';
    signal buffer_reg : std_logic_vector(7 downto 0) := "11111111";
    signal state      : std_logic := '0';
    signal start      : std_logic := '0';

begin

    -------------------------------------------------------------------------
    -- Chip Select Register (SD CS)
    -------------------------------------------------------------------------
    process (RESET, CLK, A, WR, DI)
    begin
        if (RESET = '1') then
            cs <= '1';
        elsif (CLK'event and CLK = '1') then
            if (WR = '1' and A = '1') then
                cs <= DI(0);
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Data Buffer Register
    -------------------------------------------------------------------------
    process (RESET, CLK, A, WR, DI)
    begin
        if (RESET = '1') then
            buffer_reg <= (others => '1');
        elsif (CLK'event and CLK = '1') then
            if (WR = '1' and A = '0') then
                buffer_reg <= DI;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Start Flag Generation
    -------------------------------------------------------------------------
    process (RESET, CLK, A, WR, state)
    begin
        if (RESET = '1' or state = '1') then
            start <= '0';
        elsif (CLK'event and CLK = '1') then
            if (WR = '1' and A = '0') then
                start <= '1';
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- SPI Shift Register State Machine (SCK domain)
    -------------------------------------------------------------------------
    process (RESET, SCK, start, buffer_reg)
    begin
        if (RESET = '1') then
            state     <= '0';
            cnt       <= "000";
            shift_reg <= "11111111";

        elsif (SCK'event and SCK = '0') then
            case state is
                when '0' =>
                    if (start = '1') then
                        shift_reg <= buffer_reg;
                        cnt       <= "000";
                        state     <= '1';
                    end if;

                when '1' =>
                    if (cnt = "111") then
                        state <= '0';
                    end if;
                    shift_reg <= shift_reg(6 downto 0) & MISO;
                    cnt       <= cnt + 1;

                when others => null;
            end case;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Output Assignments
    -------------------------------------------------------------------------
    BUSY <= state;
    DO   <= shift_reg;
    CS_n <= cs;
    MOSI <= shift_reg(7);
    SCLK <= SCK when state = '1' else '0';

end architecture rtl;