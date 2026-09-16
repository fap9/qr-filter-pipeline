library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

--! \file rst_monitor.vhd
--! \brief Observes clock and reset of the PL, drives five board LEDs.
--!
--! Purely passive: no data path, no AXI, no connection to the filter chain.
--! Sits in parallel to the pipeline and answers the question whether the PL
--! gets a clock at all and whether its reset is released.

entity rst_monitor is
  port (
    aclk : in std_logic; --! FCLK_CLK0
    peripheral_aresetn : in std_logic_vector(0 downto 0); --! rst_fclk0 output
    fclk_reset0_n : in std_logic; --! straight from the PS7
    ext_reset_in : in std_logic_vector(0 downto 0); --! after the inverter
    led : out std_logic_vector(4 downto 0)
  );
end entity;

architecture rtl of rst_monitor is

  --! free running, no reset: proves the clock is alive
  signal cnt : unsigned(26 downto 0) := (others => '0');

  --! sticky flag, catches a reset release that is too short to see
  signal seen_release : std_logic := '0';

begin

  process(aclk)
  begin
    if rising_edge(aclk) then
      cnt <= cnt + 1;
      if peripheral_aresetn(0) = '1' then
        seen_release <= '1';
      end if;
    end if;
  end process;

  led(0) <= peripheral_aresetn(0); --! LD0 must be lit
  led(1) <= fclk_reset0_n; --! LD1 must be lit
  led(2) <= ext_reset_in(0); --! LD2 must be dark
  led(3) <= std_logic(cnt(26)); --! LD3 blinks at 0.75 Hz when FCLK is 100 MHz
  led(4) <= seen_release; --! LD4 lit once the reset was ever released

end architecture;
