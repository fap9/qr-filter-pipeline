library ieee;
use ieee.std_logic_1164.all;


---- ENTITY
entity axis_filter_top is
  generic (
    IMAGE_WIDTH : integer := 640;
    IMAGE_HEIGHT : integer := 480
  );
  port (
    aclk : in  std_logic;
    aresetn : in  std_logic;

    -- AXIS in (RGB888)
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;
    s_axis_tdata  : in  std_logic_vector(23 downto 0);
    s_axis_tuser  : in  std_logic;
    s_axis_tlast  : in  std_logic;

    -- AXIS out (GRAY8)
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tdata : out std_logic_vector(7 downto 0);
    m_axis_tuser : out std_logic;
    m_axis_tlast : out std_logic
  );
end entity;


-- ARCHITECTURE
architecture rtl of axis_filter_top is
  -- stage connections
  signal v1,v2 : std_logic;
  signal r1,r2,r3 : std_logic;
  signal u1,u2 : std_logic;
  signal l1,l2 : std_logic;
  signal d1 : std_logic_vector(7 downto 0);
  signal d2 : std_logic_vector(7 downto 0);
  signal d3 : std_logic_vector(7 downto 0);


begin
  -- Stage 1: RGB -> Gray
  u_2gray: entity work.axis_rgb2gray
    generic map(
      IMAGE_WIDTH => IMAGE_WIDTH,
      IMAGE_HEIGHT => IMAGE_HEIGHT
    )
    port map(
      aclk => aclk, aresetn => aresetn,
      -- in
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => r1,
      s_axis_tdata => s_axis_tdata,
      s_axis_tuser => s_axis_tuser,
      s_axis_tlast => s_axis_tlast,
      -- out
      m_axis_tvalid => v1,
      m_axis_tready => r2,
      m_axis_tdata => d1,
      m_axis_tuser => u1,
      m_axis_tlast => l1
    );

  -- Stage 2: Median 3x3
  u_median: entity work.median
    generic map(
      IMAGE_WIDTH => IMAGE_WIDTH,
      IMAGE_HEIGHT => IMAGE_HEIGHT
    )
    port map(
      aclk => aclk, aresetn => aresetn,
      -- in
      s_axis_tvalid => v1,
      s_axis_tready => r2,
      s_axis_tdata => d1,
      s_axis_tuser => u1,
      s_axis_tlast => l1,
      -- out
      m_axis_tvalid => v2,
      m_axis_tready => r3,
      m_axis_tdata => d2,
      m_axis_tuser => u2,
      m_axis_tlast => l2
    );

  -- Stage 3: Gauss 3x3
  u_gauss: entity work.gauss
    generic map(
      IMAGE_WIDTH => IMAGE_WIDTH,
      IMAGE_HEIGHT => IMAGE_HEIGHT
    )
    port map(
      aclk => aclk, aresetn => aresetn,
      -- in
      s_axis_tvalid => v2,
      s_axis_tready => r3,
      s_axis_tdata => d2,
      s_axis_tuser => u2,
      s_axis_tlast => l2,
      -- out
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      m_axis_tdata => d3,
      m_axis_tuser => m_axis_tuser,
      m_axis_tlast => m_axis_tlast
    );

  m_axis_tdata <= d3;
  s_axis_tready <= r1;
end architecture;
