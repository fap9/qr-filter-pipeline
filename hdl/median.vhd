library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
--------------------------------------------------------------------------------
-- 3x3 median filter on an AXI4-Stream of 8 bit grayscale pixels.
-- Throughput is one pixel per clock cycle when the stream is not stalled.
--
-- cernel construction
--   Two line buffers hold row-1 and row-2, the current row comes straight
--   from the input. Three horizontal shift registers form the 3x3 cernel,
--   its centre being row-1 / column-1 relative to the pixel just accepted.


entity median is
  generic (
    IMAGE_WIDTH : integer := 640;
    IMAGE_HEIGHT : integer := 480
  );
  port (
    aclk : in std_logic;
    aresetn : in std_logic;

    -- AXIS in: Gray8
    s_axis_tvalid : in std_logic;
    s_axis_tready : out std_logic;
    s_axis_tdata : in std_logic_vector(7 downto 0);
    s_axis_tuser : in std_logic; -- SOF
    s_axis_tlast : in std_logic; -- EOL

    -- AXIS out: Gray8 (median)
    m_axis_tvalid : out std_logic;
    m_axis_tready : in std_logic;
    m_axis_tdata : out std_logic_vector(7 downto 0);
    m_axis_tuser : out std_logic;
    m_axis_tlast : out std_logic
  );
end entity;



architecture rtl of median is

  subtype u8 is unsigned(7 downto 0);
  type line_t is array (0 to IMAGE_WIDTH-1) of u8;

  -- Latency from a pixel entering the window registers to the corresponding median appearing on out_pix:
  --   sr stage -> sort stage 1 -> sort stage 2 -> out_pix
  constant PIPE_DEPTH : integer := 3;
  constant PIXELS_TOTAL : integer := IMAGE_WIDTH * IMAGE_HEIGHT;

  ------------------------------------------------------------------
  -- line buffers, ping-pong
  signal line0, line1 : line_t;
  signal wr_sel : std_logic := '0'; -- '0' -> write line0, '1' -> write line1

  ------------------------------------------------------------------
  -- input side position
  signal in_col : integer range 0 to IMAGE_WIDTH-1 := 0;
  signal in_row : unsigned(15 downto 0) := (others => '0');

  ------------------------------------------------------------------
  -- 3x3 window registers': sr0 = row-2, sr1 = row-1, src = current row, _a = left, _b = centre, _c = right
  signal sr0_a, sr0_b, sr0_c : u8 := (others => '0');
  signal sr1_a, sr1_b, sr1_c : u8 := (others => '0');
  signal src_a, src_b, src_c : u8 := (others => '0');

  ------------------------------------------------------------------
  -- sorting network registers
  -- stage 1: each column sorted
  signal lo_a, mid_a, hi_a : u8 := (others => '0');
  signal lo_b, mid_b, hi_b : u8 := (others => '0');
  signal lo_c, mid_c, hi_c : u8 := (others => '0');
  -- stage 2: cross comparison
  signal maxmin, medmed, minmax : u8 := (others => '0');
  -- stage 3: result
  signal out_pix : u8 := (others => '0');
  
  -- valid chain alongside the datapath, drivin tvalid (bc at start is pipeline empty
  signal vld_q : std_logic_vector(0 to PIPE_DEPTH) := (others => '0'); 

  ------------------------------------------------------------------
  -- output side position, used to regenerate SOF / EOL (input flags came one line to early)
  signal out_col : integer range 0 to IMAGE_WIDTH-1 := 0;
  signal out_row : unsigned(15 downto 0) := (others => '0');
  signal out_first : std_logic := '1'; -- next output pixel starts a frame

  ------------------------------------------------------------------
  -- frame bookkeeping and drain control
  signal frame_active : std_logic := '0'; -- a frame is being received
  signal frame_rows : unsigned(15 downto 0) := (others => '0'); -- rows seen
  signal draining : std_logic := '0';  -- window center is one line above and 3regs -> pixel in pipeline
  signal pixels_out : unsigned(31 downto 0) := (others => '0');

  ------------------------------------------------------------------
  -- handshake
  signal advance : std_logic; -- ready to set out pixel 
  signal fire : std_logic; -- an input pixel is consumed
  signal step : std_logic; -- datapath advances (input pixel or drain)
  signal frame_done : std_logic; -- frame last pixel is being retired


  ------------------------------------------------------------------
  -- comparator primitives
  function cmin(a, b : u8) return u8 is
  begin
    if a < b then
      return a;
    else
      return b;
    end if;
  end function;

  function cmax(a, b : u8) return u8 is
  begin
    if a < b then
      return b;
    else
      return a;
    end if;
  end function;

  -- median of three, depth 3 comparators
  function med3(p, q, r : u8) return u8 is
  begin
    return cmax(cmin(p, q), cmin(cmax(p, q), r));
  end function;

  -- sort three values, depth 3 comparators
  procedure sort3(x, y, z : in u8;
                  lo, mid, hi : out u8) is
    variable t1, t2, h1 : u8;
  begin
    t1 := cmin(x, y);
    t2 := cmax(x, y);
    lo := cmin(t1, z);
    h1 := cmax(t1, z);
    mid := cmin(t2, h1);
    hi := cmax(t2, h1);
  end procedure;

begin

  ------------------------------------------------------------------
  -- handshake
  --   The pipeline may advance whenever the output is either free or
  --   currently accepted. During drain no input is consumed.
  advance <= (not vld_q(PIPE_DEPTH)) or m_axis_tready;
  fire <= s_axis_tvalid and advance and (not draining);
  frame_done <= '1' when (draining = '1') and (vld_q(PIPE_DEPTH) = '1') and
                        (m_axis_tready = '1') and (pixels_out + 1 >= PIXELS_TOTAL)
                    else '0';
  step <= (fire or (draining and advance)) and (not frame_done);

  s_axis_tready <= advance and (not draining);  -- new pixel

  ------------------------------------------------------------------
  -- main process
  process(aclk)
    variable pix : u8; -- pixel fed into the window this cycle
    variable rd_m1, rd_m2 : u8; -- neighbours from row-1 and row-2
    variable v_lo, v_mid, v_hi : u8;
    variable last_in_row : boolean;
    variable cur_col : integer range 0 to IMAGE_WIDTH-1; -- position this pixel belongs to
    variable cur_row : unsigned(15 downto 0);
    variable cur_sel : std_logic; -- line buffer selection for this pixel
    
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then

        wr_sel <= '0';
        in_col <= 0;
        in_row <= (others => '0');

        sr0_a <= (others => '0'); sr0_b <= (others => '0'); sr0_c <= (others => '0');
        sr1_a <= (others => '0'); sr1_b <= (others => '0'); sr1_c <= (others => '0');
        src_a <= (others => '0'); src_b <= (others => '0'); src_c <= (others => '0');

        lo_a <= (others => '0'); mid_a <= (others => '0'); hi_a <= (others => '0');
        lo_b <= (others => '0'); mid_b <= (others => '0'); hi_b <= (others => '0');
        lo_c <= (others => '0'); mid_c <= (others => '0'); hi_c <= (others => '0');

        maxmin <= (others => '0'); medmed <= (others => '0'); minmax <= (others => '0');
        out_pix <= (others => '0');

        vld_q <= (others => '0');

        out_col <= 0;
        out_row <= (others => '0');
        out_first <= '1';

        frame_active <= '0';
        frame_rows <= (others => '0');
        draining <= '0';
        pixels_out <= (others => '0');

      else
        --------------------------------------------------------------
        -- retire an output beat
        if (vld_q(PIPE_DEPTH) = '1') and (m_axis_tready = '1') then
          pixels_out <= pixels_out + 1;

          if out_col = IMAGE_WIDTH-1 then
            out_col <= 0;
            out_row <= out_row + 1;
          else
            out_col <= out_col + 1;
          end if;

          out_first <= '0';

          -- frame complete: stop draining and rearm for the next frame
          if (draining = '1') and (pixels_out + 1 >= PIXELS_TOTAL) then  -- +1 bc acc after clk
            draining <= '0';
            frame_active <= '0';
            frame_rows <= (others => '0');
            pixels_out <= (others => '0');
            vld_q <= (others => '0'); -- whatever is still in the pipeline must not be prepended to the next frame
            out_col <= 0;
            out_row <= (others => '0');
            out_first <= '1';
          end if;
        end if;

        --------------------------------------------------------------
        -- datapath: advance on an input pixel or during drain
        if step = '1' then
        
          -- On SOF the frame restarts, so the registered counters still hold the tail of the previous 
          -- frame and must not be used for this beat.
          if (fire = '1') and (s_axis_tuser = '1') then
            cur_col := 0;
            cur_row := (others => '0');
            cur_sel := '0';
            frame_active <= '1';
            frame_rows <= (others => '0');
          else
            cur_col := in_col;
            cur_row := in_row;
            cur_sel := wr_sel;
          end if;
          
          if fire = '1' then
            pix := unsigned(s_axis_tdata);
            last_in_row := (s_axis_tlast = '1');
          else
            -- drain: replicate the last pixel of the current row
            pix := src_c;
            last_in_row := (cur_col = IMAGE_WIDTH-1);
          end if;

          ------------------------------------------------------------
          -- vertical neighbours, replicate at the top border
          if cur_row = 0 then  -- no line above
            rd_m1 := pix;
            rd_m2 := pix;
          elsif cur_row = 1 then  -- one line above
            if cur_sel = '0' then
              rd_m1 := line1(cur_col);
            else
              rd_m1 := line0(cur_col);
            end if;
            rd_m2 := rd_m1;
          else  -- all neighbours available
            if cur_sel = '0' then
              rd_m1 := line1(cur_col);
              rd_m2 := line0(cur_col);
            else
              rd_m1 := line0(cur_col);
              rd_m2 := line1(cur_col);
            end if;
          end if;

          ------------------------------------------------------------
          -- horizontal shift, replicate at the left border
          if cur_col = 0 then
            sr0_a <= rd_m2; sr0_b <= rd_m2; sr0_c <= rd_m2;
            sr1_a <= rd_m1; sr1_b <= rd_m1; sr1_c <= rd_m1;
            src_a <= pix; src_b <= pix; src_c <= pix;
          else
            sr0_a <= sr0_b; sr0_b <= sr0_c; sr0_c <= rd_m2;
            sr1_a <= sr1_b; sr1_b <= sr1_c; sr1_c <= rd_m1;
            src_a <= src_b; src_b <= src_c; src_c <= pix;
          end if;

          ------------------------------------------------------------
          -- store the current pixel for the next two rows
          if cur_sel = '0' then
            line0(cur_col) <= pix;
          else
            line1(cur_col) <= pix;
          end if;

          ------------------------------------------------------------
          -- input side counters
          if last_in_row then
            in_col <= 0;
            in_row <= cur_row + 1;
            wr_sel <= not cur_sel;
            if fire = '1' then
              frame_rows <= frame_rows + 1;
            end if;
          else
            in_col <= cur_col + 1;
            in_row <= cur_row;
            wr_sel <= cur_sel;
          end if;
          
          ------------------------------------------------------------
          -- last pixel of the frame consumed -> switch to drain in same cycle. Deriving from row counter would leave
          -- tready asserted for one more cycle and swallow the next SOF.
          if (fire = '1') and last_in_row and (cur_row = IMAGE_HEIGHT-1) then
            draining <= '1';
          end if;

          ------------------------------------------------------------
          -- sorting network          
          -- stage 1: sort each column
          sort3(sr0_a, sr1_a, src_a, v_lo, v_mid, v_hi);
          lo_a <= v_lo; mid_a <= v_mid; hi_a <= v_hi;

          sort3(sr0_b, sr1_b, src_b, v_lo, v_mid, v_hi);
          lo_b <= v_lo; mid_b <= v_mid; hi_b <= v_hi;

          sort3(sr0_c, sr1_c, src_c, v_lo, v_mid, v_hi);
          lo_c <= v_lo; mid_c <= v_mid; hi_c <= v_hi;
          
          -- stage 2: largest of the minima, median of the medians, smallest of the maxima
          maxmin <= cmax(cmax(lo_a, lo_b), lo_c);
          medmed <= med3(mid_a, mid_b, mid_c);
          minmax <= cmin(cmin(hi_a, hi_b), hi_c);
          
          -- stage 3: median of those three is the median of all nne
          out_pix <= med3(maxmin, medmed, minmax);

          ------------------------------------------------------------
          -- valid chain: Window centre is valid once one full line plus the
          --   window half width has been shifted in. Before that pipeline produces no output.
          if (cur_row >= 1) and ((cur_row > 1) or (cur_col >= 1)) then
            vld_q(0) <= '1';
          else
            vld_q(0) <= '0';
          end if;

          for k in 0 to PIPE_DEPTH-1 loop
            vld_q(k+1) <= vld_q(k);
          end loop;

        elsif (vld_q(PIPE_DEPTH) = '1') and (m_axis_tready = '1') then
          -- output consumed but nothing new arrived (avoid duplicat pixel)
          vld_q(PIPE_DEPTH) <= '0';
        end if;

      end if;
    end if;
  end process;

  ------------------------------------------------------------------
  -- output flags regenerated from the output counters
  m_axis_tvalid <= vld_q(PIPE_DEPTH);
  m_axis_tdata <= std_logic_vector(out_pix);
  m_axis_tuser <= out_first;
  m_axis_tlast <= '1' when out_col = IMAGE_WIDTH-1 else '0';

end architecture;
