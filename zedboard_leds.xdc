# ----------------------------------------------------------------------------
# Monitor LEDs, ZedBoard user LEDs LD0 to LD4, IO bank 33 (fixed 3.3 V)
set_property -dict {PACKAGE_PIN T22 IOSTANDARD LVCMOS33} [get_ports {led_0[0]}]
set_property -dict {PACKAGE_PIN T21 IOSTANDARD LVCMOS33} [get_ports {led_0[1]}]
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports {led_0[2]}]
set_property -dict {PACKAGE_PIN U21 IOSTANDARD LVCMOS33} [get_ports {led_0[3]}]
set_property -dict {PACKAGE_PIN V22 IOSTANDARD LVCMOS33} [get_ports {led_0[4]}]



