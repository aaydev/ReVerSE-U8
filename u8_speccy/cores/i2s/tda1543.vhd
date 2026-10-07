-------------------------------------------------------------------------------
-- I2S Master Controller (TDA1543) Mode MSB First
-------------------------------------------------------------------------------
-- V0.1    12.02.2011  First version
-- V0.2
-------------------------------------------------------------------------------
--
-- STATE     01  02  03  04  05  06  07  08  09  0A  0B  ..  0F  10  11  12  13  14  15  16  17  18  19  1A  1B  ..  1F  00
--      ___  __  __  __  __  __  __  __  __  __  __  __  ..  __  __  __  __  __  __  __  __  __  __  __  __  __  ..  __  __  ____
-- DATA    \/LS\/MS\/  \/  \/  \/  \/  \/  \/  \/  \/  \/  \/  \/  \/LS\/MS\/  \/  \/  \/  \/  \/  \/  \/  \/  \/  \/  \/  \/   
--      ___/\__/\__/\__/\__/\__/\__/\__/\__/\__/\__/\__/\../\__/\__/\__/\__/\__/\__/\__/\__/\__/\__/\__/\__/\__/\../\__/\__/\____
--          -0- -F- -E- -D- -C- -B- -A- -9- -8- -7- -6-  .. -2- -1- -0- -F- -E- -D- -C- -B- -A- -9- -8- -7- -6-  .. -2- -1- 
--        _   _   _   _   _   _   _   _   _   _   _   _  ..   _   _   _   _   _   _   _   _   _   _   _   _   _  ..   _   _   _ 
-- BCK   | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | |
--      _| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_
--             |
--      ___    |                                                    _____________________________________________..________ 
-- WS      |   |            LEFT                                   |                RIGHT                                  |
--         |___|_________________________________________..________|                                                       |______
--             |SAMPLE OUT
-------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.std_logic_unsigned.all;

entity tda1543 is
    port (
        RESET   : in  std_logic;
        CLK     : in  std_logic;
        CS      : in  std_logic;
        DATA_L  : in  std_logic_vector(15 downto 0);
        DATA_R  : in  std_logic_vector(15 downto 0);
        BCK     : out std_logic;
        WS      : out std_logic;
        DATA    : out std_logic
    );
end entity tda1543;

architecture tda1543_arch of tda1543 is

    -------------------------------------------------------------------------
    -- Internal Signals
    -------------------------------------------------------------------------
    signal shift_reg : std_logic_vector(31 downto 0) := (others => '0');
    signal bit_cnt   : std_logic_vector(4 downto 0)  := (others => '0');

begin

    -------------------------------------------------------------------------
    -- I2S Shift Register Process (MSB First)
    -------------------------------------------------------------------------
    process (RESET, CLK, CS)
    begin
        if (RESET = '1' or CS = '0') then
            shift_reg <= (others => '0');
            bit_cnt   <= (others => '0');

        elsif (CLK'event and CLK = '0') then
            bit_cnt   <= bit_cnt + "00001";
            shift_reg <= shift_reg(30 downto 0) & '0';
            DATA      <= shift_reg(31);

            if bit_cnt = "00000" then
                -- Start LEFT channel, load shift register
                WS        <= '0';
                shift_reg <= DATA_L & DATA_R;
            elsif bit_cnt = "10000" then
                -- Start RIGHT channel
                WS <= '1';
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Output Assignments
    -------------------------------------------------------------------------
    BCK <= CLK when CS = '1' else '1';

end architecture tda1543_arch;