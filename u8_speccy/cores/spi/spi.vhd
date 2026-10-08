-------------------------------------------------------------------------------
-- SPI Master
-------------------------------------------------------------------------------
-- V0.1.0   31.01.2011  First version
-- V0.2.0   31.08.2013  Rewritten controller. Independent operation from system clock
-- V0.2.1   01.09.2013  Fixed controller
-- V0.3.0   14.01.2017  Refactored: removed internal CS control, added I_/O_ port prefixes
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity spi is
    port (
        I_RESET : in  std_logic;                     -- 1 = active reset
        I_CLK   : in  std_logic;                     -- Controller system clock
        I_SCK   : in  std_logic;                     -- SPI interface clock
        I_DI    : in  std_logic_vector(7 downto 0);  -- Data 8 bits, input
        O_DO    : out std_logic_vector(7 downto 0);  -- Data 8 bits, output
        I_WR    : in  std_logic;                     -- 1 = write data to data register
        O_BUSY  : out std_logic;                     -- 1 = transfer in progress; 0 = completed
        O_SCLK  : out std_logic;                     -- SPI clock output
        O_MOSI  : out std_logic;                     -- Master Out Slave In
        I_MISO  : in  std_logic                      -- Master In Slave Out
    );
end entity spi;

architecture rtl of spi is

    -------------------------------------------------------------------------
    -- Internal Signals
    -------------------------------------------------------------------------
    signal cnt        : std_logic_vector(2 downto 0) := "000";       -- Bit counter
    signal shift_reg  : std_logic_vector(7 downto 0) := "11111111";  -- Shift register
    signal buffer_reg : std_logic_vector(7 downto 0) := "11111111";
    signal state      : std_logic := '0';
    signal start      : std_logic := '0';

begin

    -------------------------------------------------------------------------
    -- Data Buffer Register
    -------------------------------------------------------------------------
    process (I_RESET, I_CLK, I_WR, I_DI)
    begin
        if (I_RESET = '1') then
            buffer_reg <= (others => '1');
        elsif (I_CLK'event and I_CLK = '1') then
            if (I_WR = '1') then
                buffer_reg <= I_DI;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Start Flag Generation
    -------------------------------------------------------------------------
    process (I_RESET, I_CLK, I_WR, state)
    begin
        if (I_RESET = '1' or state = '1') then
            start <= '0';
        elsif (I_CLK'event and I_CLK = '1') then
            if (I_WR = '1') then
                start <= '1';
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- SPI Shift Register State Machine (SCK domain)
    -------------------------------------------------------------------------
    process (I_RESET, I_SCK, start, buffer_reg)
    begin
        if (I_RESET = '1') then
            state     <= '0';
            cnt       <= "000";
            shift_reg <= "11111111";

        elsif (I_SCK'event and I_SCK = '0') then
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
                    shift_reg <= shift_reg(6 downto 0) & I_MISO;
                    cnt       <= cnt + 1;

                when others => null;
            end case;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Output Assignments
    -------------------------------------------------------------------------
    O_BUSY <= state;
    O_DO   <= shift_reg;
    O_MOSI <= shift_reg(7);
    O_SCLK <= I_SCK when state = '1' else '0';

end architecture rtl;