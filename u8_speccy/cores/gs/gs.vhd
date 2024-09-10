-------------------------------------------------------------------[15.02.2014]
-- General Sound
-------------------------------------------------------------------------------
-- V0.1 11/01/2011 first version
-- V0.2
-- V0.3 12/19/2011 CPU @ 84MHz, INT# confirmation
-- V0.4 05/10/2013 bit7_flag, bit0_flag fixed
-- V0.5 05/29/2013 channel volume added, CPU @ 21MHz
-- V0.6 07/21/2013 int_n fixed


-- CPU: Z80
-- ROM: 32K
-- RAM: 480K
-- INT: 37.5KHz

-- #xxBB Command register - writable command register
-- #xxBB Status register - readable status register
-- bit 7 data flag
-- bit <6:1> Not defined
-- bit 0 command flag. This register allows you to determine the state of the GS, in particular whether it is possible to read or write the next byte of data, or issue the next command, etc.
-- #xxB3 Data register - writable data register. Spectrum writes data to this register, for example, these can be command arguments.
-- #xxB3 Output register - readable output register. Spectrum reads data from this register coming from the GS

-- Internal ports:
-- #xx00 "extended memory" - writable register
-- bit <3:0> switches pages by 32Kb, page 0 - ROM
-- bit <7:0> not used

-- ports 1-5 "provide communication with SPECTRUM"
-- #xx01 General Sound command read
-- bit <7:0> command code
-- #xx02 General Sound data read
-- bit <7:0> data
-- #xx03 General Sound data write for SPECTRUM
-- bit <7:0> data
-- #xx04 General Sound status word read
-- bit 0 command flag
-- bit 7 data flag
-- #xx05 resets bit D0 (command flag) of status word

-- ports 6-9 "volume control" in channels 1 - 4
-- #xx06 "volume control" on channel 1
-- bit <5:0> volume
-- bit <7:6> not used
-- #xx07 "volume control" on channel 2
-- bit <5:0> volume
-- bit <7:6> not used
-- #xx08 "volume control" on channel 3
-- bit <5:0> volume
-- bit <7:6> not used
-- #xx09 "volume control" on channel 4
-- bit <5:0> volume
-- bit <7:6> not used

-- #xx0A sets bit 7 of the status word not equal to bit 0 of port #xx00
-- #xx0B sets bit 0 of the status word equal to bit 5 of port #xx06

--Memory allocation
--#0000 - #3FFF - first 16Kb ROM
--#4000 - #7FFF - first 16Kb of the first page of RAM
--#8000 - #FFFF - scrollable pages of 32Kb
-- page 0 - ROM,
-- page 1 - first page of RAM
-- pages 2... RAM

--Data is entered into channels automatically when the processor reads RAM at addresses #6000 - #7FFF.

library IEEE; 
use IEEE.std_logic_1164.all; 
use IEEE.std_logic_unsigned.all;
use IEEE.numeric_std.all;
use IEEE.STD_LOGIC_ARITH.all;

entity gs is
	Port ( 
		RESET		: in std_logic;
		CLK			: in std_logic;
		CLKGS		: in std_logic;
		A			: in std_logic_vector(15 downto 0);
		DI			: in std_logic_vector(7 downto 0);
		DO			: out std_logic_vector(7 downto 0);
		WR_n		: in std_logic;
		RD_n		: in std_logic;
		IORQ_n		: in std_logic;
		M1_n		: in std_logic;
		OUTA		: out std_logic_vector(13 downto 0);
		OUTB		: out std_logic_vector(13 downto 0);
		OUTC		: out std_logic_vector(13 downto 0);
		OUTD		: out std_logic_vector(13 downto 0);
		MA			: out std_logic_vector(18 downto 0);
		MDI			: in std_logic_vector(7 downto 0);
		MDO			: out std_logic_vector(7 downto 0);
		MWE_n		: out std_logic);
end gs;
 
architecture gs_unit of gs is
	signal port_xxbb_reg	: std_logic_vector(7 downto 0);
	signal port_xxb3_reg 	: std_logic_vector(7 downto 0);
	signal port_xx00_reg 	: std_logic_vector(7 downto 0);
	signal port_xx03_reg 	: std_logic_vector(7 downto 0);
	signal port_xx06_reg 	: std_logic_vector(5 downto 0);
	signal port_xx07_reg 	: std_logic_vector(5 downto 0);
	signal port_xx08_reg 	: std_logic_vector(5 downto 0);
	signal port_xx09_reg 	: std_logic_vector(5 downto 0);
	signal ch_a_reg 		: std_logic_vector(7 downto 0);
	signal ch_b_reg 		: std_logic_vector(7 downto 0);
	signal ch_c_reg 		: std_logic_vector(7 downto 0);
	signal ch_d_reg 		: std_logic_vector(7 downto 0);
	signal bit7_flag		: std_logic;
	signal bit0_flag		: std_logic;
	signal cnt				: std_logic_vector(9 downto 0);
	signal int_n			: std_logic;
	signal mem				: std_logic_vector(4 downto 0);
	signal out_a			: std_logic_vector(13 downto 0);
	signal out_b			: std_logic_vector(13 downto 0);
	signal out_c			: std_logic_vector(13 downto 0);
	signal out_d			: std_logic_vector(13 downto 0);
	
	-- CPU
	signal cpu_m1_n			: std_logic;
	signal cpu_mreq_n		: std_logic;
	signal cpu_iorq_n		: std_logic;
	signal cpu_rd_n			: std_logic;
	signal cpu_wr_n			: std_logic;
	signal cpu_a_bus		: std_logic_vector(15 downto 0);
	signal cpu_di_bus		: std_logic_vector(7 downto 0);
	signal cpu_do_bus		: std_logic_vector(7 downto 0);

begin

z80_unit: entity work.t80s
generic map (
	Mode		=> 0,	-- 0 => Z80, 1 => Fast Z80, 2 => 8080, 3 => GB
	T2Write		=> 1,	-- 0 => WR_n active in T3, 1 => WR_n active in T2
	IOWait		=> 1)	-- 0 => Single cycle I/O, 1 => Std I/O cycle
port map(
	RESET_n		=> not RESET,
	--CLK_n		=> not CLKGS,
	CLK		=> CLKGS,
	WAIT_n		=> '1',
	INT_n		=> int_n,
	NMI_n		=> '1',
	BUSRQ_n		=> '1',
	M1_n		=> cpu_m1_n,
	MREQ_n		=> cpu_mreq_n,
	IORQ_n		=> cpu_iorq_n,
	RD_n		=> cpu_rd_n,
	WR_n		=> cpu_wr_n,
	RFSH_n		=> open,
	HALT_n		=> open,
	BUSAK_n		=> open,
	A			=> cpu_a_bus,
	DI			=> cpu_di_bus,
	DO			=> cpu_do_bus,
	SavePC      => open,
	SaveINT     => open,
	RestorePC   => (others => '1'),
	RestoreINT  => (others => '1'),
	RestorePC_n => '1');
	
process (CLKGS, cnt)
begin
	if CLKGS'event and CLKGS = '1' then
		cnt <= cnt + 1;
		if cnt = "1000110000" then	-- 21MHz / 560 = 0.0375MHz = 37.5kHz
			cnt <= (others => '0');
		end if;
	end if;
end process;

-- INT#
process (CLKGS, cpu_iorq_n, cpu_m1_n, cnt)
begin
	if cpu_iorq_n = '0' and cpu_m1_n = '0' then
		int_n <= '1';
	elsif CLKGS'event and CLKGS = '1' then
		if cnt = "1000110000" then
			int_n <= '0';
		end if;
	end if;
end process;

process (CLKGS, cpu_iorq_n, cpu_m1_n, cpu_a_bus, IORQ_n, RD_n, A, WR_n)
begin
	if (cpu_iorq_n = '0' and cpu_m1_n = '1' and cpu_a_bus(3 downto 0) = X"2") or (IORQ_n = '0' and RD_n = '0' and A(7 downto 0) = X"B3") then
		bit7_flag <= '0';
	elsif (cpu_iorq_n = '0' and cpu_m1_n = '1' and cpu_a_bus(3 downto 0) = X"3") or (IORQ_n = '0' and WR_n = '0' and A(7 downto 0) = X"B3") then
		bit7_flag <= '1';
	elsif CLKGS'event and CLKGS = '1' then
		if (cpu_iorq_n = '0' and cpu_m1_n = '1' and cpu_a_bus(3 downto 0) = X"A") then
			bit7_flag <= not port_xx00_reg(0);
		end if;
	end if;
end process;

process (CLKGS, cpu_iorq_n, cpu_m1_n, cpu_a_bus, IORQ_n, RD_n, A, WR_n)
begin
	if cpu_iorq_n = '0' and cpu_m1_n = '1' and cpu_a_bus(3 downto 0) = X"5" then
		bit0_flag <= '0';
	elsif IORQ_n = '0' and WR_n = '0' and A(7 downto 0) = X"BB" then
		bit0_flag <= '1';
	elsif CLKGS'event and CLKGS = '1' then
		if (cpu_iorq_n = '0' and cpu_m1_n = '1' and cpu_a_bus(3 downto 0) = X"B") then
			bit0_flag <= port_xx06_reg(5);
		end if;
	end if;
end process;

process (CLK, A, IORQ_n, WR_n, RESET)
begin
-- recording from the spectrum side
 	if RESET = '1' then
		port_xxbb_reg <= (others => '0');
		port_xxb3_reg <= (others => '0');
	elsif CLK'event and CLK = '1' then
		if IORQ_n = '0' and WR_n = '0' and A(7 downto 0) = X"BB" then port_xxbb_reg <= DI; end if;
		if IORQ_n = '0' and WR_n = '0' and A(7 downto 0) = X"B3" then port_xxb3_reg <= DI; end if;
	end if;
end process;

process (A, bit7_flag, bit0_flag, port_xx03_reg)
begin	
-- recording from the spectrum side
	if A(3) = '1' then	-- port #xxBB
		DO <= bit7_flag & "111111" & bit0_flag;
	else				-- port #xxB3
		DO <= port_xx03_reg;
	end if;
end process;

process (CLKGS, RESET, cpu_a_bus, cpu_m1_n, port_xx00_reg)
begin
	if RESET = '1' then
		port_xx00_reg <= (others => '0');
        port_xx03_reg <= (others => '0');
        port_xx06_reg <= (others => '0');
        port_xx07_reg <= (others => '0');
        port_xx08_reg <= (others => '0');
        port_xx09_reg <= (others => '0');
		ch_a_reg <= (others => '0');
		ch_b_reg <= (others => '0');
		ch_c_reg <= (others => '0');
		ch_d_reg <= (others => '0');
		
	elsif CLKGS'event and CLKGS = '1' then
		if cpu_iorq_n = '0' and cpu_wr_n = '0' and cpu_a_bus(3 downto 0) = X"0" then port_xx00_reg <= cpu_do_bus; end if;
		if cpu_iorq_n = '0' and cpu_wr_n = '0' and cpu_a_bus(3 downto 0) = X"3" then port_xx03_reg <= cpu_do_bus; end if;
		if cpu_iorq_n = '0' and cpu_wr_n = '0' and cpu_a_bus(3 downto 0) = X"6" then port_xx06_reg <= cpu_do_bus(5 downto 0); end if;
		if cpu_iorq_n = '0' and cpu_wr_n = '0' and cpu_a_bus(3 downto 0) = X"7" then port_xx07_reg <= cpu_do_bus(5 downto 0); end if;
		if cpu_iorq_n = '0' and cpu_wr_n = '0' and cpu_a_bus(3 downto 0) = X"8" then port_xx08_reg <= cpu_do_bus(5 downto 0); end if;
		if cpu_iorq_n = '0' and cpu_wr_n = '0' and cpu_a_bus(3 downto 0) = X"9" then port_xx09_reg <= cpu_do_bus(5 downto 0); end if;
		
		if cpu_mreq_n = '0' and cpu_rd_n = '0' and cpu_a_bus(15 downto 13) = "011" and cpu_a_bus(9 downto 8) = "00" then ch_a_reg <= MDI; end if;
		if cpu_mreq_n = '0' and cpu_rd_n = '0' and cpu_a_bus(15 downto 13) = "011" and cpu_a_bus(9 downto 8) = "01" then ch_b_reg <= MDI; end if;
		if cpu_mreq_n = '0' and cpu_rd_n = '0' and cpu_a_bus(15 downto 13) = "011" and cpu_a_bus(9 downto 8) = "10" then ch_c_reg <= MDI; end if;
		if cpu_mreq_n = '0' and cpu_rd_n = '0' and cpu_a_bus(15 downto 13) = "011" and cpu_a_bus(9 downto 8) = "11" then ch_d_reg <= MDI; end if;
	end if;

	case cpu_a_bus(15 downto 14) is
		when "00" => mem <= "00000";										--#0000 - #3FFF  -  first 16Kb ROM
		when "01" => mem <= "00010";										--#4000 - #7FFF  -  first 16Kb of the first page of RAM
		when others => mem <= port_xx00_reg(3 downto 0) & cpu_a_bus(14);	--#8000 - #FFFF  -  printed pages of 32Kb
	end case;
end process;

-- CPU data bus
cpu_di_bus <=	MDI when (cpu_mreq_n = '0' and cpu_rd_n = '0') else
				bit7_flag & "111111" & bit0_flag when (cpu_iorq_n = '0' and cpu_rd_n = '0' and cpu_a_bus(3 downto 0) = X"4") else
				port_xxbb_reg when (cpu_iorq_n = '0' and cpu_rd_n = '0' and cpu_a_bus(3 downto 0) = X"1") else
				port_xxb3_reg when (cpu_iorq_n = '0' and cpu_rd_n = '0' and cpu_a_bus(3 downto 0) = X"2") else
				"11111111";

OUTA 	<= ch_a_reg * port_xx06_reg;
OUTB 	<= ch_b_reg * port_xx07_reg;
OUTC 	<= ch_c_reg * port_xx08_reg;
OUTD 	<= ch_d_reg * port_xx09_reg;
MA		<= mem & cpu_a_bus(13 downto 0);
MDO 	<= cpu_do_bus;
MWE_n 	<= cpu_wr_n or cpu_mreq_n or not (mem(4) or mem(3) or mem(2) or mem(1));

end gs_unit;