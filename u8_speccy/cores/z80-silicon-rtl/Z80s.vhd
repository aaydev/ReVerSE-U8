--------------------------------------------------------------------------------
-- Z80 CPU core wrapper (Verilog core with savestate and T2Write support)
--------------------------------------------------------------------------------
-- The CPU itself is the RTL reconstruction of the NMOS Z80 written in Verilog:
--
--   Z80.v               - main core module + bus control, ALU, interrupt logic
--   Registers.v         - register bank
--   Register_selector.v - register pair selection logic
--
-- All three files are self contained and have to be added to the project
-- (VERILOG_FILE) together with this wrapper (VHDL_FILE).
--
-- This wrapper only adapts the core to the conventions used in this project:
--   * the core drives active high levels, the design uses active low "_n" names
--   * the core has an explicit bus request/release interface (BUSRQ_n/BUSAK_n)
--     and tri-state control outputs (DATA_Z/ADR_Z/CONTROLS_Z), which are not
--     used here because the CPU bus is not shared with another master
--
-- Timing: CLK is the CPU clock and is used on both edges by the core
-- (the T state counter advances on the falling edge), so CLK has to be the
-- real (gated) CPU clock - see cpuclk in u8speccy.vhd/u9speccy.vhd.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity Z80s is
    generic (
        Mode    : integer := 0;   -- 0 => Z80, 1 => Fast Z80, 2 => 8080, 3 => GB
        T2Write : integer := 1;   -- 0 => WR_n active in T3, 1 => WR_n active in T2
        IOWait  : integer := 0    -- 0 => Single cycle I/O, 1 => Std I/O cycle
    );
    port (
        RESET_n     : in  std_logic;
        CLK         : in  std_logic;
        WAIT_n      : in  std_logic := '1';
        INT_n       : in  std_logic := '1';
        NMI_n       : in  std_logic := '1';
        BUSRQ_n     : in  std_logic := '1';
        M1_n        : out std_logic;
        MREQ_n      : out std_logic;
        IORQ_n      : out std_logic;
        RD_n        : out std_logic;
        WR_n        : out std_logic;
        RFSH_n      : out std_logic;
        HALT_n      : out std_logic;
        BUSAK_n     : out std_logic;
        A           : out std_logic_vector(15 downto 0);
        DI          : in  std_logic_vector(7 downto 0);
        DO          : out std_logic_vector(7 downto 0);
        SavePC      : out std_logic_vector(15 downto 0);
        SaveINT     : out std_logic_vector(7 downto 0);
        RestorePC   : in  std_logic_vector(15 downto 0) := (others => '0');
        RestoreINT  : in  std_logic_vector(7 downto 0)  := (others => '0');
        RestorePC_n : in  std_logic := '1'
    );
end entity Z80s;

architecture rtl of Z80s is

    signal mreq, iorq, rd, wr, rfsh, m1, halt, busack : std_logic;
    signal save_pc    : std_logic_vector(15 downto 0);
    signal save_int   : std_logic_vector(7 downto 0);
    signal restore_en : std_logic;

    component Z80 is
        generic (
            T2Write : integer := 1
        );
        port (
            clk         : in  std_logic;
            data_in     : in  std_logic_vector(7 downto 0);
            data_out    : out std_logic_vector(7 downto 0);
            adr         : out std_logic_vector(15 downto 0);
            mreq        : out std_logic;
            iorq        : out std_logic;
            rd          : out std_logic;
            wr          : out std_logic;
            data_z      : out std_logic;
            adr_z       : out std_logic;
            controls_z  : out std_logic;
            rfsh        : out std_logic;
            p_m1        : out std_logic;
            halt        : out std_logic;
            p_wait      : in  std_logic;
            p_int       : in  std_logic;
            nmi         : in  std_logic;
            reset       : in  std_logic;
            busrq       : in  std_logic;
            busack      : out std_logic;
            save_pc     : out std_logic_vector(15 downto 0);
            save_int    : out std_logic_vector(7 downto 0);
            restore_pc  : in  std_logic_vector(15 downto 0);
            restore_int : in  std_logic_vector(7 downto 0);
            restore_en  : in  std_logic
        );
    end component Z80;

begin

    restore_en <= not RestorePC_n;

    U0 : Z80
        generic map (
            T2Write => T2Write
        )
        port map (
            clk         => CLK,
            data_in     => DI,
            data_out    => DO,
            adr         => A,
            mreq        => mreq,
            iorq        => iorq,
            rd          => rd,
            wr          => wr,
            data_z      => open,
            adr_z       => open,
            controls_z  => open,
            rfsh        => rfsh,
            p_m1        => m1,
            halt        => halt,
            p_wait      => not WAIT_n,
            p_int       => not INT_n,
            nmi         => not NMI_n,
            reset       => not RESET_n,
            busrq       => not BUSRQ_n,
            busack      => busack,
            save_pc     => save_pc,
            save_int    => save_int,
            restore_pc  => RestorePC,
            restore_int => RestoreINT,
            restore_en  => restore_en
        );

    M1_n    <= not m1;
    MREQ_n  <= not mreq;
    IORQ_n  <= not iorq;
    RD_n    <= not rd;
    WR_n    <= not wr;
    RFSH_n  <= not rfsh;
    HALT_n  <= not halt;
    BUSAK_n <= not busack;

    SavePC  <= save_pc;
    SaveINT <= save_int;

end architecture rtl;