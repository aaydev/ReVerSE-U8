--------------------------------------------------------------------------------
-- Z80 CPU core wrapper (Verilog core)
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

entity Z80s is
    port (
        RESET_n : in  std_logic;                     -- 0 = reset
        CLK     : in  std_logic;                     -- CPU clock
        WAIT_n  : in  std_logic := '1';              -- 0 = insert a memory wait state
        INT_n   : in  std_logic := '1';              -- maskable interrupt request
        NMI_n   : in  std_logic := '1';              -- non maskable interrupt request
        BUSRQ_n : in  std_logic := '1';              -- bus request
        M1_n    : out std_logic;                     -- opcode fetch cycle (M1)
        MREQ_n  : out std_logic;                     -- memory request
        IORQ_n  : out std_logic;                     -- I/O request
        RD_n    : out std_logic;                     -- read
        WR_n    : out std_logic;                     -- write
        RFSH_n  : out std_logic;                     -- refresh
        HALT_n  : out std_logic;                     -- halted
        BUSAK_n : out std_logic;                     -- bus acknowledge
        A       : out std_logic_vector(15 downto 0);
        DI      : in  std_logic_vector(7 downto 0);
        DO      : out std_logic_vector(7 downto 0)
    );
end entity Z80s;

architecture rtl of Z80s is

    signal mreq   : std_logic;
    signal iorq   : std_logic;
    signal rd     : std_logic;
    signal wr     : std_logic;
    signal rfsh   : std_logic;
    signal m1     : std_logic;
    signal halt   : std_logic;
    signal busack : std_logic;

    -- Zilog Z80 CPU, Verilog core (Z80.v)
    -- A component declaration is used instead of "entity work.Z80": Quartus binds
    -- the Verilog module by name at elaboration time, so the HDL file order in the
    -- project does not matter (direct entity instantiation would require the
    -- Verilog sources to be analysed before this VHDL file - error 10481).
    component Z80 is
        port (
            clk        : in  std_logic;
            data_in    : in  std_logic_vector(7 downto 0);
            data_out   : out std_logic_vector(7 downto 0);
            adr        : out std_logic_vector(15 downto 0);
            mreq       : out std_logic;
            iorq       : out std_logic;
            rd         : out std_logic;
            wr         : out std_logic;
            data_z     : out std_logic;
            adr_z      : out std_logic;
            controls_z : out std_logic;
            rfsh       : out std_logic;
            p_m1       : out std_logic;
            halt       : out std_logic;
            p_wait     : in  std_logic;
            p_int      : in  std_logic;
            nmi        : in  std_logic;
            reset      : in  std_logic;
            busrq      : in  std_logic;
            busack     : out std_logic
        );
    end component Z80;

begin

    -- Zilog Z80 CPU
    U0 : Z80
        port map (
            clk        => CLK,
            data_in    => DI,
            data_out   => DO,
            adr        => A,
            mreq       => mreq,
            iorq       => iorq,
            rd         => rd,
            wr         => wr,
            data_z     => open,              -- data bus is not shared
            adr_z      => open,              -- address bus is not shared
            controls_z => open,              -- control lines are not shared
            rfsh       => rfsh,
            p_m1       => m1,
            halt       => halt,
            p_wait     => not WAIT_n,        -- p_wait is active high
            p_int      => not INT_n,
            nmi        => not NMI_n,
            reset      => not RESET_n,
            busrq      => not BUSRQ_n,
            busack     => busack
        );

    -- active high (core) to active low (design)
    M1_n    <= not m1;
    MREQ_n  <= not mreq;
    IORQ_n  <= not iorq;
    RD_n    <= not rd;
    WR_n    <= not wr;
    RFSH_n  <= not rfsh;
    HALT_n  <= not halt;
    BUSAK_n <= not busack;

end architecture rtl;