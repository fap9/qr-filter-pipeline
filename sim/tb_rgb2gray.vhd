library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
--------------------------------------------------------------------------------
-- Sends one 16x8 RGB frame, compares every output beat against the reference
-- Y = (77R + 150G + 29B + 128) >> 8 and checks that SOF and EOL appear exactly
-- on the first pixel of the frame and on the last pixel of each row. Run for 50 us.
-- checker reports.

entity tb_rgb2gray is
end entity;



architecture sim of tb_rgb2gray is

  constant W : integer := 16;
  constant H : integer := 8;
  constant PIXELS : integer := W * H;
  constant CLK_PERIOD : time := 10 ns;

  constant GAP_PERCENT : integer := 0;--15; -- source keeps tvalid low
  constant BP_PERCENT : integer := 0;--30; -- sink keeps tready low

  ------------------------------------------------------------------
  -- deterministic test image, with black and white as explicit corner cases
  function gen_r(i : integer) return integer is
  begin
    if i = 0 then
      return 0;
    elsif i = 1 then
      return 255;
    end if;
    return (i * 37 + 1) mod 256;
  end function;

  function gen_g(i : integer) return integer is
  begin
    if i = 0 then
      return 0;
    elsif i = 1 then
      return 255;
    end if;
    return (i * 91 + 5) mod 256;
  end function;

  function gen_b(i : integer) return integer is
  begin
    if i = 0 then
      return 0;
    elsif i = 1 then
      return 255;
    end if;
    return (i * 53 + 11) mod 256;
  end function;

  -- golden model, integer division truncates which is what >> 8 does here
  function ref_y(i : integer) return integer is
  begin
    return (77 * gen_r(i) + 150 * gen_g(i) + 29 * gen_b(i) + 128) / 256;
  end function;

  ------------------------------------------------------------------
  signal aclk : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal s_axis_tvalid : std_logic := '0';
  signal s_axis_tready : std_logic;
  signal s_axis_tdata : std_logic_vector(23 downto 0) := (others => '0');
  signal s_axis_tuser : std_logic := '0';
  signal s_axis_tlast : std_logic := '0';

  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic := '0';
  signal m_axis_tdata : std_logic_vector(7 downto 0);
  signal m_axis_tuser : std_logic;
  signal m_axis_tlast : std_logic;

begin
  ------------------------------------------------------------------
  dut : entity work.axis_rgb2gray
    generic map (
      IMAGE_WIDTH => W,
      IMAGE_HEIGHT => H
    )
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      s_axis_tdata => s_axis_tdata,
      s_axis_tuser => s_axis_tuser,
      s_axis_tlast => s_axis_tlast,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      m_axis_tdata => m_axis_tdata,
      m_axis_tuser => m_axis_tuser,
      m_axis_tlast => m_axis_tlast
    );

  ------------------------------------------------------------------
  clkgen : process
  begin
    aclk <= '0';
    wait for CLK_PERIOD / 2;
    aclk <= '1';
    wait for CLK_PERIOD / 2;
  end process;

  rstgen : process
  begin
    aresetn <= '0';
    wait for 10 * CLK_PERIOD;
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait;
  end process;

  ------------------------------------------------------------------
  -- source
  stim : process
    variable seed1 : positive := 1;
    variable seed2 : positive := 7;
    variable rnd : real;
    variable i : integer;
  begin
    s_axis_tvalid <= '0';
    s_axis_tdata <= (others => '0');
    s_axis_tuser <= '0';
    s_axis_tlast <= '0';

    wait until aresetn = '1';
    wait until rising_edge(aclk);

    i := 0;
    while i < PIXELS loop
      uniform(seed1, seed2, rnd);

      if integer(rnd * 100.0) < GAP_PERCENT then
        -- idle beat, drive X so that a DUT latching without fire is caught
        s_axis_tvalid <= '0';
        s_axis_tdata <= (others => 'X');
        s_axis_tuser <= 'X';
        s_axis_tlast <= 'X';
        wait until rising_edge(aclk);

      else
        s_axis_tvalid <= '1';
        s_axis_tdata <= std_logic_vector(to_unsigned(gen_r(i), 8)) &
                        std_logic_vector(to_unsigned(gen_g(i), 8)) &
                        std_logic_vector(to_unsigned(gen_b(i), 8));

        if i = 0 then
          s_axis_tuser <= '1';
        else
          s_axis_tuser <= '0';
        end if;

        if (i mod W) = W-1 then
          s_axis_tlast <= '1';
        else
          s_axis_tlast <= '0';
        end if;

        -- hold the beat until it is accepted
        loop
          wait until rising_edge(aclk);
          exit when s_axis_tready = '1';
        end loop;

        i := i + 1;
      end if;
    end loop;

    s_axis_tvalid <= '0';
    s_axis_tdata <= (others => '0');
    s_axis_tuser <= '0';
    s_axis_tlast <= '0';
    wait;
  end process;

  ------------------------------------------------------------------
  -- sink and checker
  sink : process
    variable seed1 : positive := 3;
    variable seed2 : positive := 11;
    variable rnd : real;
    variable idx : integer := 0;
    variable got_y : integer;
    variable exp_y : integer;
    variable exp_user : std_logic;
    variable exp_last : std_logic;
    variable err_data : integer := 0;
    variable err_flag : integer := 0;
    
  begin
    m_axis_tready <= '0';
    wait until aresetn = '1';

    while idx < PIXELS loop
      uniform(seed1, seed2, rnd);
      if integer(rnd * 100.0) < BP_PERCENT then
        m_axis_tready <= '0';
      else
        m_axis_tready <= '1';
      end if;

      wait until rising_edge(aclk);

      if (m_axis_tvalid = '1') and (m_axis_tready = '1') then
        got_y := to_integer(unsigned(m_axis_tdata));
        exp_y := ref_y(idx);

        if got_y /= exp_y then
          err_data := err_data + 1;
          if err_data <= 10 then
            report "pixel " & integer'image(idx) &
                   ": expected " & integer'image(exp_y) &
                   ", got " & integer'image(got_y)
              severity error;
          end if;
        end if;

        if idx = 0 then
          exp_user := '1';
        else
          exp_user := '0';
        end if;

        if (idx mod W) = W-1 then
          exp_last := '1';
        else
          exp_last := '0';
        end if;

        if (m_axis_tuser /= exp_user) or (m_axis_tlast /= exp_last) then
          err_flag := err_flag + 1;
          if err_flag <= 10 then
            report "flag error at pixel " & integer'image(idx) &
                   ": tuser " & std_logic'image(m_axis_tuser) &
                   ", tlast " & std_logic'image(m_axis_tlast)
              severity error;
          end if;
        end if;

        idx := idx + 1;
      end if;
    end loop;

    m_axis_tready <= '0';

    report "RESULT  BP " & integer'image(BP_PERCENT) & " % / GAP " &
           integer'image(GAP_PERCENT) & " % : " &
           integer'image(idx) & "/" & integer'image(PIXELS) &
           ", data " & integer'image(err_data) &
           ", SOF/EOL " & integer'image(err_flag);

    if (err_data = 0) and (err_flag = 0) then
      report "PASS";
    else
      report "FAIL" severity failure;
    end if;

    finish;
  end process;

  ------------------------------------------------------------------
  watchdog : process
  begin
    wait for 50 us;
    report "TIMEOUT: not all pixels left the pipeline, check the handshake"
      severity failure;
    wait;
  end process;

end architecture;
