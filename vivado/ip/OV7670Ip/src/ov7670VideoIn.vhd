----------------------------------------------------------------------------------
-- Authors: rodrifer <rodrifer@dte.uma.es>
--          martin   <martin@uma.es>
-- Company: ASIN
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;


entity ov7670_video_in is
    port (
        pclk              : in  std_logic;
        vsync             : in  std_logic;
        href              : in  std_logic;
        datain            : in  std_logic_vector (7 downto 0);
--        mode0             : in std_logic;
--        mode1             : in std_logic;
--        mode2             : in std_logic;
        video_data        : out std_logic_vector ( 23 downto 0 );
        active_video      : out std_logic;
        video_hsync      : out std_logic;
        video_vsync      : out std_logic
    );
end ov7670_video_in;

architecture behavioral of ov7670_video_in is
    signal d_latch          : std_logic_vector(15 downto 0) := (others => '0');
    signal href_last        : std_logic;
    signal vsync_last       : std_logic;
    signal EvenOdd          : std_logic; -- 0: even byte; 1: odd byte
    signal FirstByte        : std_logic_vector(7 downto 0);

begin

 -- Expand 16-bit RGB (5:6:5) to 24-bit RGB (8:8:8)

video_data  <=    d_latch(15 downto 11) & d_latch(11) & d_latch(11) & d_latch(11) 
               &  d_latch(10 downto  5) & d_latch(5)  & d_latch(5) 
               &  d_latch( 4 downto  0) & d_latch(0)  & d_latch(0)  & d_latch(0);
     
active_video <= href_last when rising_edge(pclk);
video_hsync <= not href_last when rising_edge(pclk);
video_vsync <= vsync_last when rising_edge(pclk);


capture_process: process
begin
  wait until rising_edge(pclk);
  
  href_last <= href;
  vsync_last <= vsync;
  
  if href='0' and href_last='0' then              -- horizontal blanking

    d_latch <= (others=>'0');
    EvenOdd <= '0';

  else

    if EvenOdd='0' then 
      FirstByte <= datain;
    else
      d_latch <= FirstByte & datain;
    end if;
    
    EvenOdd <= not EvenOdd;    
  end if;
    
end process;

end behavioral;