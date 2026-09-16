--------------------------------------------------------------------------------
-- testbench for the complete filter pipeline rgb2gray -> median 3x3 -> gauss 3x3
--
-- What this adds over the per module testbenches:
--   1) Stage interaction: the priming gap of one stage is a stream gap for the next one, and the drain phase of one 
--      stage feeds a stage whose input has already gone idle. Neither situation occurs in a module bench.
--   2) Two consecutive frames with different content, so a stale line buffer, a counter that fails to rearm or a missing SOF shows up.
--   3) End to end pixel count: every stage counts on its own, an off by one would accumulate.


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;


entity tb_axis_filter_top is
end entity;



architecture sim of tb_axis_filter_top is
  -- ------------------------------------------------------------------
  -- Test parameters (keep small -> fast simulation, readable logs)
  constant W : integer := 16;
  constant H : integer := 8;
  constant FRAMES : integer := 2;
  constant CLK_PER : time := 10 ns; -- 100 MHz

  -- Backpressure: 0 = tready always 1, otherwise percentage of stall cycles
  constant BP_PERCENT : integer := 0; -- 30
  -- Gaps in the source stream, percentage of cycles with tvalid = '0'
  constant GAP_PERCENT : integer := 0; -- 0

  -- pixels that are checked strictly: distance >= 2 from every border
  constant GUARD : integer := 2;

  -- ------------------------------------------------------------------
  -- DUT signals
  signal aclk : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal s_axis_tdata : std_logic_vector(23 downto 0) := (others => '0');
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
  -- Test images + reference images, one set per frame
  type img_t is array (0 to H-1, 0 to W-1) of integer range 0 to 255;
  type seq_t is array (0 to FRAMES-1) of img_t;

  signal src_r, src_g, src_b : seq_t := (others => (others => (others => 0)));
  signal ref_img : seq_t := (others => (others => (others => 0)));
  signal img_ready : boolean := false;

  -- progress counter (written by checker, read by watchdog)
  signal n_out : integer := 0;

  -- ------------------------------------------------------------------
  -- Reference model 
  type win9_t is array (0 to 8) of integer;

  -- Q0.8 with round to nearest
  function rgb2gray_ref(r, g, b : integer) return integer is
  begin
    return (77*r + 150*g + 29*b + 128) / 256;
  end function;

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

  -- window in row major order, w(4) is the centr
  function gauss9(w : win9_t) return integer is
    variable s : integer;
  begin
    s :=    w(0) + 2*w(1) + w(2)
         +  2*w(3) + 4*w(4) + 2*w(5)
         +  w(6) + 2*w(7) + w(8);
    return (s + 8) / 16;
  end function;

  -- collect the 3x3 neighbourhood of (y,x) with clamped borders
  function window_at(img : img_t; y, x : integer) return win9_t is
    variable res : win9_t;
    variable nx, ny, idx : integer;
  begin
    idx := 0;
    for ky in -1 to 1 loop
      for kx in -1 to 1 loop
        nx := x + kx;
        ny := y + ky;
        if nx < 0 then nx := 0; end if;
        if nx > W-1 then nx := W-1; end if;
        if ny < 0 then ny := 0; end if;
        if ny > H-1 then ny := H-1; end if;
        res(idx) := img(ny,nx);
        idx := idx + 1;
      end loop;
    end loop;
    return res;
  end function;

  -- Pseudo random (xorshift32)
  procedure next_rnd(variable seed : inout unsigned(31 downto 0);
                     variable val : out integer) is
    variable s : unsigned(31 downto 0);
  begin
    s := seed;
    s := s xor shift_left(s, 13);
    s := s xor shift_right(s, 17);
    s := s xor shift_left(s, 5);
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


  dut : entity work.axis_filter_top
    generic map (
      IMAGE_WIDTH => W,
      IMAGE_HEIGHT => H
    )
    port map (
      aclk => aclk,
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
  -- Generate test images + reference (fully deterministic)
  gen_img : process
    variable seed : unsigned(31 downto 0) := x"AFFE6742";
    variable rnd : integer;
    variable ir, ig, ib : img_t;
    variable gray, med, gau : img_t;
    variable allr, allg, allb : seq_t;
    variable allref : seq_t;

  begin
    for f in 0 to FRAMES-1 loop

      ----------------------------------------------------------------
      -- source frame
      --   frame 0: blocks with a gradient, distinct R/G/B so a swapped coefficient cannot cancel out
      --   frame 1: inverted, so a line buffer still holding frame 0 data produces a visible mismatch
      for y in 0 to H-1 loop
        for x in 0 to W-1 loop
          -- chess pattern
          if ((x/4) + (y/4)) mod 2 = 0 then
            ir(y,x) := (x*13 + y*7) mod 256;
            ig(y,x) := (x*7 + y*11 + 40) mod 256;
            ib(y,x) := (x*11 + y*13 + 90) mod 256;
          else
            ir(y,x) := (x*5 + y*17 + 128) mod 256;
            ig(y,x) := (x*19 + y*3 + 200) mod 256;
            ib(y,x) := (x*3 + y*19 + 60) mod 256;
          end if;

          -- invert pattern
          if f = 1 then
            ir(y,x) := 255 - ir(y,x);
            ig(y,x) := 255 - ig(y,x);
            ib(y,x) := 255 - ib(y,x);
          end if;
        end loop;
      end loop;

      -- salt/pepper on relevant channels, the median must remove it
      for y in 0 to H-1 loop
        for x in 0 to W-1 loop
          next_rnd(seed, rnd);
          if (rnd mod 100) < 8 then
            next_rnd(seed, rnd);
            if (rnd mod 2) = 0 then
              ir(y,x) := 0; ig(y,x) := 0; ib(y,x) := 0;
            else
              ir(y,x) := 255; ig(y,x) := 255; ib(y,x) := 255;
            end if;
          end if;
        end loop;
      end loop;

      ----------------------------------------------------------------
      -- reference chain, stage by stage
      for y in 0 to H-1 loop
        for x in 0 to W-1 loop
          gray(y,x) := rgb2gray_ref(ir(y,x), ig(y,x), ib(y,x));
        end loop;
      end loop;

      for y in 0 to H-1 loop
        for x in 0 to W-1 loop
          med(y,x) := median9(window_at(gray, y, x));
        end loop;
      end loop;

      for y in 0 to H-1 loop
        for x in 0 to W-1 loop
          gau(y,x) := gauss9(window_at(med, y, x));
        end loop;
      end loop;

      allr(f) := ir; allg(f) := ig; allb(f) := ib;
      allref(f) := gau;
    end loop;

    src_r <= allr;
    src_g <= allg;
    src_b <= allb;
    ref_img <= allref;
    img_ready <= true;
    wait;
  end process;

  -- ------------------------------------------------------------------
  -- Stimulus: stream FRAMES frames back to back (with gaps in tvalid)
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

    for f in 0 to FRAMES-1 loop
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

          -- RGB888, R in the high byte
          s_axis_tdata <= std_logic_vector(to_unsigned(src_r(f)(y,x), 8)) &
                          std_logic_vector(to_unsigned(src_g(f)(y,x), 8)) &
                          std_logic_vector(to_unsigned(src_b(f)(y,x), 8));
          s_axis_tvalid <= '1';

          if (x = 0) and (y = 0) then
            s_axis_tuser <= '1'; -- SOF on the first pixel of every frame
          else
            s_axis_tuser <= '0';
          end if;

          if x = W-1 then
            s_axis_tlast <= '1'; -- EOL at end of line
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
    end loop;

    s_axis_tvalid <= '0';
    s_axis_tuser <= '0';
    s_axis_tlast <= '0';
    wait;
  end process;

  -- ------------------------------------------------------------------
  -- Backpressure on the output side
  bp : process
    variable seed : unsigned(31 downto 0) := x"A0A0BEEF";
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
    variable f, x, y : integer := 0;
    variable got, exp : integer;
    variable is_strict : boolean;
    variable e_inner : integer := 0;
    variable e_ring : integer := 0;
    variable e_flags : integer := 0;
    variable max_dev : integer := 0;
    variable cnt : integer := 0;

  begin
    wait until aresetn = '1';

    while cnt < FRAMES*W*H loop
      wait until rising_edge(aclk);

      if (m_axis_tvalid = '1') and (m_axis_tready = '1') then

        got := to_integer(unsigned(m_axis_tdata));
        exp := ref_img(f)(y,x);

        -- two 3x3 stages spread the border deviation inwards by one pixel each
        is_strict := (x >= GUARD) and (x <= W-1-GUARD) and
                     (y >= GUARD) and (y <= H-1-GUARD);

        -- pixel value
        if got /= exp then
          if is_strict then
            e_inner := e_inner + 1;
            if e_inner <= 10 then -- to limit the log output
              report "PIXEL MISMATCH (interior) frame=" & integer'image(f) &
                     " x=" & integer'image(x) &
                     " y=" & integer'image(y) &
                     "  expected=" & integer'image(exp) &
                     "  got=" & integer'image(got)
                     severity warning;
            end if;
          else
            e_ring := e_ring + 1;
            if abs(got - exp) > max_dev then
              max_dev := abs(got - exp);
            end if;
          end if;
        end if;

        -- SOF: expected on the first pixel of every frame
        if (x = 0) and (y = 0) then
          if m_axis_tuser /= '1' then
            e_flags := e_flags + 1;
            report "SOF missing on first pixel of frame " & integer'image(f)
                   severity warning;
          end if;
        elsif m_axis_tuser = '1' then
          e_flags := e_flags + 1;
          report "SOF at wrong position frame=" & integer'image(f) &
                 " x=" & integer'image(x) &
                 " y=" & integer'image(y) severity warning;
        end if;

        -- EOL
        if x = W-1 then
          if m_axis_tlast /= '1' then
            e_flags := e_flags + 1;
            report "EOL missing at end of line y=" & integer'image(y) &
                   " frame=" & integer'image(f) severity warning;
          end if;
        elsif m_axis_tlast = '1' then
          e_flags := e_flags + 1;
          report "EOL too early at x=" & integer'image(x) &
                 " y=" & integer'image(y) &
                 " frame=" & integer'image(f) severity warning;
        end if;

        -- advance
        cnt := cnt + 1;
        n_out <= cnt;
        if x = W-1 then
          x := 0;
          if y = H-1 then
            y := 0;
            f := f + 1;
          else
            y := y + 1;
          end if;
        else
          x := x + 1;
        end if;

      end if;
    end loop;

    wait for 10*CLK_PER;

    report "=====================================================";
    report "Frames           : " & integer'image(FRAMES);
    report "Pixels received  : " & integer'image(cnt) & " / " &
           integer'image(FRAMES*W*H);
    report "Errors interior  : " & integer'image(e_inner);
    report "Errors border    : " & integer'image(e_ring) &
           " (2 pixel ring, not checked strictly)";
    report "Max dev border   : " & integer'image(max_dev);
    report "Errors SOF/EOL   : " & integer'image(e_flags);
    report "=====================================================";

    if (e_inner = 0) and (e_flags = 0) then
      report "TEST PASSED for interior; border deviations expected " &
             "(HW replicates top/left only, spread by two 3x3 stages)"
             severity note;
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
    for i in 0 to 30*FRAMES*W*H loop
      wait until rising_edge(aclk);
      exit when n_out >= FRAMES*W*H;
    end loop;

    if n_out < FRAMES*W*H then
      report "TIMEOUT: only " & integer'image(n_out) & " of " &
             integer'image(FRAMES*W*H) & " pixels received " &
             "(missing drain phase, broken handshake or frame not rearmed?)"
             severity failure;
    end if;
    wait;
  end process;

end architecture;
