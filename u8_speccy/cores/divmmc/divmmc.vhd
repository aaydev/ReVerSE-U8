-------------------------------------------------------------------------------
-- DivMMC
-------------------------------------------------------------------------------
-- V0.1.0   27.03.2014  First version
-- V0.1.1   30.03.2014  Fixed automap generation, instant switching on 3Dxx was not taken into account
-- V0.2.0   01.04.2014  Fixed switching after opcode read (author shurik-ua)
-- V0.3.0   Updated automap logic (mapram/conmem support, RD_N check), improved SPI interface
-------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity divmmc is
    port (
        CLK     : in  std_logic;
        EN      : in  std_logic;
        RESET   : in  std_logic;
        ADDR    : in  std_logic_vector(15 downto 0);
        DI      : in  std_logic_vector(7 downto 0);
        DO      : out std_logic_vector(7 downto 0);
        WR_N    : in  std_logic;
        RD_N    : in  std_logic;
        IORQ_N  : in  std_logic;
        MREQ_N  : in  std_logic;
        M1_N    : in  std_logic;
        E3REG   : out std_logic_vector(7 downto 0);
        AMAP    : out std_logic;
        CS_N    : out std_logic;
        SCLK    : out std_logic;
        MOSI    : out std_logic;
        MISO    : in  std_logic
    );
end entity divmmc;

architecture rtl of divmmc is

    -------------------------------------------------------------------------
    -- Internal Signals
    -------------------------------------------------------------------------
    signal cnt       : std_logic_vector(3 downto 0);
    signal cnt_en    : std_logic;
    signal cs        : std_logic := '1';
    signal reg_e3    : std_logic_vector(7 downto 0) := "00000000";
    signal automap   : std_logic := '0';
    signal detect    : std_logic := '0';
    signal shift_in  : std_logic_vector(7 downto 0) := (others => '1');
    signal shift_out : std_logic_vector(7 downto 0) := (others => '1');
    signal mapram    : std_logic;
    signal conmem    : std_logic;

begin

    -------------------------------------------------------------------------
    -- Register Control Process
    -------------------------------------------------------------------------
    process (RESET, CLK, WR_N, ADDR, IORQ_N, EN, DI)
    begin
        if (RESET = '1') then
            cs <= '1';
            reg_e3 <= (others => '0');
        elsif (CLK'event and CLK = '1') then
            if (IORQ_N = '0' and WR_N = '0' and EN = '1' and ADDR(7 downto 0) = X"E3") then
                reg_e3 <= DI;
            end if;
            if (IORQ_N = '0' and WR_N = '0' and EN = '1' and ADDR(7 downto 0) = X"E7") then
                cs <= DI(0);
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Automap Logic Process
    -------------------------------------------------------------------------
    mapram <= reg_e3(6);
    conmem <= reg_e3(7);

    process (CLK)
    begin
        if (CLK'event and CLK = '1') then
            -- Activated when fetching opcode in M1 cycle at specified addresses
            if (M1_N = '0' and MREQ_N = '0' and RD_N = '0' and (EN = '1' or mapram = '1') and
                (ADDR = X"0000" or ADDR = X"0008" or ADDR = X"0038" or
                 ADDR = X"0066" or ADDR = X"04C6" or ADDR = X"0562")) then
                detect <= '1';
            -- Instant switching without waiting for opcode read
            elsif (M1_N = '0' and MREQ_N = '0' and RD_N = '0' and (EN = '1' or mapram = '1') and
                   ADDR(15 downto 8) = X"3D") then
                automap <= '1';
                detect <= '1';
            -- Deactivated when fetching opcode in M1 cycle at addresses 0x1FF8-0x1FFF
            elsif (M1_N = '0' and MREQ_N = '0' and RD_N = '0' and (EN = '1' or mapram = '1') and
                   ADDR(15 downto 3) = "0001111111111") then
                detect <= '0';
            end if;

            -- Switching after opcode read
            if (M1_N = '1') then
                automap <= detect;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- SPI Interface Process
    -------------------------------------------------------------------------
    cnt_en <= not cnt(3) or cnt(2) or cnt(1) or cnt(0);

    process (CLK, cnt_en, ADDR, IORQ_N, RD_N, WR_N, EN)
    begin
        if (ADDR(7 downto 0) = X"EB" and IORQ_N = '0' and EN = '1' and (WR_N = '0' or RD_N = '0')) then
            cnt <= "1110";
        else
            if (CLK'event and CLK = '0') then
                if cnt_en = '1' then
                    cnt <= cnt + 1;
                end if;
            end if;
        end if;
    end process;

    process (CLK)
    begin
        if (CLK'event and CLK = '0') then
            if (ADDR(7 downto 0) = X"EB" and WR_N = '0' and IORQ_N = '0' and EN = '1') then
                shift_out <= DI;
            else
                if cnt(3) = '0' then
                    shift_out(7 downto 0) <= shift_out(6 downto 0) & '1';
                end if;
            end if;
        end if;
    end process;

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
    DO    <= shift_in;
    CS_N  <= cs;
    MOSI  <= shift_out(7);
    SCLK  <= CLK and not cnt(3);
    E3REG <= reg_e3;
    AMAP  <= automap or conmem;

end architecture rtl;