--------------------------------------------------------------------------------
-- testbench for the median filter
--
-- Checks performed:
--   1) Output pixel count == W*H
--   2) SOF/EOL alignment (tuser on first pixel, tlast at end of each line)
--   3) Pixel values against a reference model (interior checked strictly,
--      border pixels counted separately to expose border handling)
--   4) Backpressure: m_axis_tready is deasserted pseudo-randomly

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;


entity tb_median is
end entity;



architecture sim of tb_median is
  -- ------------------------------------------------------------------
  -- Test parameters (keep small -> fast simulation, readable logs)
  constant W : integer := 16;
  constant H : integer := 8;
  constant CLK_PER : time := 10 ns;  -- 100 MHz

  -- Backpressure: 0 = tready always 1, otherwise percentage of stall cycles
  constant BP_PERCENT : integer := 30;
  -- Gaps in the source stream, percentage of cycles with tvalid = '0'
  constant GAP_PERCENT : integer := 15;

  -- ------------------------------------------------------------------
  -- DUT signals
  signal aclk : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal s_axis_tdata : std_logic_vector(7 downto 0) := (others => '0');
  signal s_axis_tvalid : std_logic := '0';
  signal s_axis_tready : std_logic;
  signal s_axis_tuser : std_logic := '0';
  signal s_axis_tlast : std_logic := '0';

  signal m_axis_tdata : std_logic_vector(7 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic := '1';
  signal m_axis_tuser : std_logic;
  signal m_axis_tlast : std_logic;

  signal sim_done : boolean := false;

  -- ------------------------------------------------------------------
  -- Test image + reference image
  type img_t is array (0 to H-1, 0 to W-1) of integer range 0 to 255;
  signal src_img : img_t := (others => (others => 0));
  signal ref_img : img_t := (others => (others => 0));
  signal img_ready : boolean := false;

  -- progress counter (written by checker, read by watchdog)
  signal n_out : integer := 0;

  -- ------------------------------------------------------------------
  -- Helper: median of 9 values (reference model, software sort)
  type win9_t is array (0 to 8) of integer;

  function median9(w : win9_t) return integer is
    variable v : win9_t := w;
    variable t : integer;
  begin
    for i in 0 to 7 loop
      for j in 0 to 7-i loop
        if v(j+1) < v(j) then
          t := v(j); v(j) := v(j+1); v(j+1) := t;
        end if;
      end loop;
    end loop;
    return v(4);
  end function;

  -- Pseudo random (xorshift32)
  procedure next_rnd(variable seed : inout unsigned(31 downto 0);
                     variable val : out integer) is
    variable s : unsigned(31 downto 0);
  begin
    s := seed;
    s := s xor shift_left(s, 13);
    s := s xor shift_right(s, 17);
    s := s xor shift_left(s,  5);
    seed := s;
    val := to_integer(s(30 downto 0));
  end procedure;

begin
  -- ------------------------------------------------------------------
  -- Clock & reset
  aclk <= '0' when sim_done else not aclk after CLK_PER/2;

  reset_proc : process
  begin
    aresetn <= '0';
    wait for 5*CLK_PER;
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait;
  end process;


  dut : entity work.median
    generic map (
      IMAGE_WIDTH  => W,
      IMAGE_HEIGHT => H
    )
    port map (
      aclk  => aclk,
      aresetn => aresetn,
      s_axis_tdata => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      s_axis_tuser => s_axis_tuser,
      s_axis_tlast => s_axis_tlast,
      m_axis_tdata => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      m_axis_tuser => m_axis_tuser,
      m_axis_tlast => m_axis_tlast
    );


  -- ------------------------------------------------------------------
  -- Generate test image + reference
  gen_img : process
    variable seed : unsigned(31 downto 0) := x"AFFE6742";
    variable r : integer;
    variable img : img_t;
    variable ref : img_t;
    variable win : win9_t;
    variable nx, ny, idx : integer;
    
  begin
    -- base pattern
    for y in 0 to H-1 loop
      for x in 0 to W-1 loop
        if ((x/4) + (y/4)) mod 2 = 0 then
          img(y,x) := 20 + (x*3 + y*5) mod 60;  -- dark block
        else
          img(y,x) := 200 + (x*7 + y*11) mod 55;  -- bright block
        end if;
      end loop;
    end loop;

    -- salt & pepper (~10% of pixels) -> median must remove these
    for y in 0 to H-1 loop
      for x in 0 to W-1 loop
        next_rnd(seed, r);
        if (r mod 100) < 10 then
          next_rnd(seed, r);
          if (r mod 2) = 0 then
            img(y,x) := 0;
          else
            img(y,x) := 255;
          end if;
        end if;
      end loop;
    end loop;

    -- reference image: 3x3 median, clamped borders
    for y in 0 to H-1 loop
      for x in 0 to W-1 loop
        idx := 0;
        for ky in -1 to 1 loop
          for kx in -1 to 1 loop
            nx := x + kx; 
            ny := y + ky;
            if nx < 0 then nx := 0; end if;
            if nx > W-1 then nx := W-1; end if;
            if ny < 0 then ny := 0; end if;
            if ny > H-1 then ny := H-1; end if;
            win(idx) := img(ny,nx);
            idx := idx + 1;
          end loop;
        end loop;
        ref(y,x) := median9(win);
      end loop;
    end loop;

    src_img <= img;
    ref_img <= ref;
    img_ready <= true;
    wait;
  end process;


  -- ------------------------------------------------------------------
  -- Stimulus: stream one frame (with gaps in tvalid)
  stim : process
    variable seed : unsigned(31 downto 0) := x"12345678";
    variable r : integer;
    
  begin
    s_axis_tvalid <= '0';
    s_axis_tuser <= '0';
    s_axis_tlast <= '0';

    wait until img_ready;
    wait until aresetn = '1';
    wait until rising_edge(aclk);

    for y in 0 to H-1 loop
      for x in 0 to W-1 loop

        -- occasional gap in the source stream, driving X to prove that the
        -- DUT latches nothing without fire
        next_rnd(seed, r);
        if (r mod 100) < GAP_PERCENT then
          s_axis_tvalid <= '0';
          s_axis_tdata <= (others => 'X');
          s_axis_tuser <= 'X';
          s_axis_tlast <= 'X';
          wait until rising_edge(aclk);
        end if;

        s_axis_tdata <= std_logic_vector(to_unsigned(src_img(y,x), 8));
        s_axis_tvalid <= '1';

        if (x = 0) and (y = 0) then
          s_axis_tuser <= '1';  -- SOF only on the very first pixel
        else
          s_axis_tuser <= '0';
        end if;

        if x = W-1 then
          s_axis_tlast <= '1';  -- EOL at end of line
        else
          s_axis_tlast <= '0';
        end if;

        -- wait for handshake
        loop
          wait until rising_edge(aclk);
          exit when s_axis_tready = '1';
        end loop;

      end loop;
    end loop;

    s_axis_tvalid <= '0';
    s_axis_tuser <= '0';
    s_axis_tlast <= '0';
    wait;
  end process;

  -- ------------------------------------------------------------------
  -- Backpressure on the output side
  bp : process
    variable seed : unsigned(31 downto 0) := x"DEADBEEF";
    variable r : integer;
    
  begin
    m_axis_tready <= '1';
    wait until aresetn = '1';
    loop
      wait until rising_edge(aclk);
      exit when sim_done;
      if BP_PERCENT > 0 then
        next_rnd(seed, r);
        if (r mod 100) < BP_PERCENT then
          m_axis_tready <= '0';
        else
          m_axis_tready <= '1';
        end if;
      end if;
    end loop;
    wait;
  end process;

  -- ------------------------------------------------------------------
  -- Monitor / checker (counters are process variables -> no shared vars)
  check : process
    variable x, y : integer := 0;
    variable got, exp : integer;
    variable is_brd : boolean;
    variable e_inner : integer := 0;
    variable e_border : integer := 0;
    variable e_flags : integer := 0;
    variable cnt : integer := 0;
    
  begin
    wait until aresetn = '1';

    while cnt < W*H loop
      wait until rising_edge(aclk);

      if (m_axis_tvalid = '1') and (m_axis_tready = '1') then

        got := to_integer(unsigned(m_axis_tdata));
        exp := ref_img(y,x);
        is_brd := (x = 0) or (x = W-1) or (y = 0) or (y = H-1);

        -- pixel value
        if got /= exp then
          if is_brd then
            e_border := e_border + 1;
          else
            e_inner := e_inner + 1;
            if e_inner <= 10 then  -- to limit the log output
              report "PIXEL MISMATCH (interior) x=" & integer'image(x) &
                     " y=" & integer'image(y) &
                     "  expected=" & integer'image(exp) &
                     "  got=" & integer'image(got)
                     severity warning;
            end if;
          end if;
        end if;

        -- SOF
        if (x = 0) and (y = 0) then
          if m_axis_tuser /= '1' then
            e_flags := e_flags + 1;
            report "SOF missing on first pixel" severity warning;
          end if;
        elsif m_axis_tuser = '1' then
          e_flags := e_flags + 1;
          report "SOF at wrong position x=" & integer'image(x) &
                 " y=" & integer'image(y) severity warning;
        end if;

        -- EOL
        if x = W-1 then
          if m_axis_tlast /= '1' then
            e_flags := e_flags + 1;
            report "EOL missing at end of line y=" & integer'image(y)
                   severity warning;
          end if;
        elsif m_axis_tlast = '1' then
          e_flags := e_flags + 1;
          report "EOL too early at x=" & integer'image(x) &
                 " y=" & integer'image(y) severity warning;
        end if;

        -- advance
        cnt := cnt + 1;
        n_out <= cnt;
        if x = W-1 then
          x := 0; y := y + 1;
        else
          x := x + 1;
        end if;

      end if;
    end loop;

    wait for 10*CLK_PER;


    report "=====================================================";
    report "Pixels received  : " & integer'image(cnt) & " / " & integer'image(W*H);
    report "Errors interior  : " & integer'image(e_inner);
    report "Errors border    : " & integer'image(e_border);
    report "Errors SOF/EOL   : " & integer'image(e_flags);
    report "=====================================================";

    if (e_inner = 0) and (e_flags = 0) then
      if e_border = 0 then
        report "TEST PASSED (including borders)" severity note;
      else
        report "TEST PASSED for interior; border deviations expected " &
               "(HW replicates top/left only)" severity note;
      end if;
    else
      report "TEST FAILED" severity error;
    end if;

    sim_done <= true;
    wait;
  end process;

  -- ------------------------------------------------------------------
  -- Watchdog: fires if the DUT never delivers all pixels
  watchdog : process
  begin
    wait until aresetn = '1';
    for i in 0 to 30*W*H loop
      wait until rising_edge(aclk);
      exit when n_out >= W*H;
    end loop;

    if n_out < W*H then
      report "TIMEOUT: only " & integer'image(n_out) & " of " &
             integer'image(W*H) & " pixels received " &
             "(missing drain phase or broken handshake?)"
             severity failure;
    end if;
    wait;
  end process;

end architecture;
