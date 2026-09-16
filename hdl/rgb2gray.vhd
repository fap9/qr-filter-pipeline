library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

--------------------------------------------------------------------------------
-- RGB888 to Gray8 on an AXI4-Stream.
--
--   Y = (77*R + 150*G + 29*B + 128) >> 8
--
-- The coefficients are BT.601 in Q0.8 (0.299 / 0.587 / 0.114 scaled by 256).
-- Adding 128 before the shift rounds to nearest instead of truncating.



entity axis_rgb2gray is
  generic (
    IMAGE_WIDTH : integer := 640;
    IMAGE_HEIGHT : integer := 480
  );
  port (
    aclk : in std_logic;
    aresetn : in std_logic;

    -- AXIS in: RGB888, [23:16] = R, [15:8] = G, [7:0] = B
    s_axis_tvalid : in std_logic;
    s_axis_tready : out std_logic;
    s_axis_tdata : in std_logic_vector(23 downto 0);
    s_axis_tuser : in std_logic; -- SOF
    s_axis_tlast : in std_logic; -- EOL

    -- AXIS out: Gray8
    m_axis_tvalid : out std_logic;
    m_axis_tready : in std_logic;
    m_axis_tdata : out std_logic_vector(7 downto 0);
    m_axis_tuser : out std_logic;
    m_axis_tlast : out std_logic
  );
end entity;



architecture rtl of axis_rgb2gray is
  -- Number of register stages after the input, counted like in the median stage: vld_q(0) is 
  -- the first register, vld_q(PIPE_DEPTH) drives tvalid. -> A single stage means PIPE_DEPTH = 0.
  constant PIPE_DEPTH : integer := 0;

  constant C_R : unsigned(7 downto 0) := to_unsigned(77, 8);
  constant C_G : unsigned(7 downto 0) := to_unsigned(150, 8);
  constant C_B : unsigned(7 downto 0) := to_unsigned(29, 8);

  ------------------------------------------------------------------
  -- datapath register
  signal out_pix : unsigned(7 downto 0) := (others => '0');

  ------------------------------------------------------------------
  -- flag pipeline running alongside the datapath
  signal vld_q : std_logic_vector(0 to PIPE_DEPTH) := (others => '0');  -- out valid and ready
  signal usr_q : std_logic_vector(0 to PIPE_DEPTH) := (others => '0');  -- SOF
  signal lst_q : std_logic_vector(0 to PIPE_DEPTH) := (others => '0');  -- EOL

  ------------------------------------------------------------------
  -- handshake
  signal advance : std_logic; -- pipeline may shift this cycle
  signal fire : std_logic; -- an input pixel is consumed

begin
  ------------------------------------------------------------------
  -- The pipeline may advance whenever output register is empty or being accepted this cycle. 
  -- tready must not depend on tvalid -> it depends on the output register state and on m_axis_tready 
  advance <= (not vld_q(PIPE_DEPTH)) or m_axis_tready;
  fire <= s_axis_tvalid and advance;
  s_axis_tready <= advance;

  ------------------------------------------------------------------
  process(aclk)
    variable vr, vg, vb : unsigned(7 downto 0);
    -- 77*255 + 150*255 + 29*255 + 128 = 65408 (17 bits never overflow)
    variable acc : unsigned(16 downto 0);
    
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        out_pix <= (others => '0');
        vld_q <= (others => '0');
        usr_q <= (others => '0');
        lst_q <= (others => '0');

      else
        if fire = '1' then
          vr := unsigned(s_axis_tdata(23 downto 16));
          vg := unsigned(s_axis_tdata(15 downto 8));
          vb := unsigned(s_axis_tdata(7 downto 0));

          -- +128 = half of 256, carries into bit 8 when the remainder is >= 0.5 (round to nearest)
          acc := resize(C_R * vr, 17) + resize(C_G * vg, 17) + resize(C_B * vb, 17) + to_unsigned(128, 17);
          -- >> 8 undoes the Q0.8 scaling
          out_pix <= acc(15 downto 8);

          vld_q(0) <= '1';
          usr_q(0) <= s_axis_tuser;
          lst_q(0) <= s_axis_tlast;

          -- null range when PIPE_DEPTH = 0, kept for symmetry with the other stages
          for k in 0 to PIPE_DEPTH-1 loop
            vld_q(k+1) <= vld_q(k);
            usr_q(k+1) <= usr_q(k);
            lst_q(k+1) <= lst_q(k);
          end loop;

        elsif (vld_q(PIPE_DEPTH) = '1') and (m_axis_tready = '1') then
          -- output consumed but no new pixel arrived: clear so pixel is not presented twice
          vld_q(PIPE_DEPTH) <= '0';
        end if;

      end if;
    end if;
  end process;

  ------------------------------------------------------------------
  m_axis_tvalid <= vld_q(PIPE_DEPTH);
  m_axis_tdata <= std_logic_vector(out_pix);
  m_axis_tuser <= usr_q(PIPE_DEPTH);
  m_axis_tlast <= lst_q(PIPE_DEPTH);

end architecture;