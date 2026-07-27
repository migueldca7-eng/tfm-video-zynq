# Zybo Z7-10 constraints for the validated TPG-VDMA-HDMI design.
#
# The camera video-data interface has been removed from this revision.
# Some legacy camera control ports remain present in the Block Design and
# are therefore kept constrained until the hardware design is cleaned up.

# -----------------------------------------------------------------------------
# External PL clock and reset
# -----------------------------------------------------------------------------

set_property PACKAGE_PIN K17 [get_ports {CLK_I}]
set_property IOSTANDARD LVCMOS33 [get_ports {CLK_I}]

set_property PACKAGE_PIN K18 [get_ports {RST_I}]
set_property IOSTANDARD LVCMOS33 [get_ports {RST_I}]

# -----------------------------------------------------------------------------
# HDMI output
# -----------------------------------------------------------------------------

set_property PACKAGE_PIN H16 [get_ports {HDMI_CLK_P}]
set_property PACKAGE_PIN D19 [get_ports {HDMI_D0_P}]
set_property PACKAGE_PIN C20 [get_ports {HDMI_D1_P}]
set_property PACKAGE_PIN B19 [get_ports {HDMI_D2_P}]

set_property IOSTANDARD TMDS_33 [get_ports {HDMI_CLK_*}]
set_property IOSTANDARD TMDS_33 [get_ports {HDMI_D*}]

# -----------------------------------------------------------------------------
# User LEDs
# -----------------------------------------------------------------------------

set_property PACKAGE_PIN M14 [get_ports {LED_O[0]}]
set_property PACKAGE_PIN M15 [get_ports {LED_O[1]}]
set_property PACKAGE_PIN G14 [get_ports {LED_O[2]}]
set_property PACKAGE_PIN D18 [get_ports {LED_O[3]}]

set_property IOSTANDARD LVCMOS33 [get_ports {LED_O[*]}]

# -----------------------------------------------------------------------------
# Legacy camera-control ports still present in the Block Design
# -----------------------------------------------------------------------------

set_property PACKAGE_PIN Y16 [get_ports {RESETCAMBUTTON}]
set_property IOSTANDARD LVCMOS33 [get_ports {RESETCAMBUTTON}]

set_property PACKAGE_PIN W14 [get_ports {RESETCAM}]
set_property IOSTANDARD LVCMOS33 [get_ports {RESETCAM}]

set_property PACKAGE_PIN U14 [get_ports {pclk}]
set_property IOSTANDARD LVCMOS33 [get_ports {pclk}]

set_property PACKAGE_PIN T15 [get_ports {xclk}]
set_property IOSTANDARD LVCMOS33 [get_ports {xclk}]

# -----------------------------------------------------------------------------
# Legacy camera I2C interface still enabled in the Processing System
# -----------------------------------------------------------------------------

set_property PACKAGE_PIN T14 [get_ports {iic_0_scl_io}]
set_property PACKAGE_PIN U15 [get_ports {iic_0_sda_io}]

set_property IOSTANDARD LVCMOS33 [get_ports {iic_0_scl_io}]
set_property IOSTANDARD LVCMOS33 [get_ports {iic_0_sda_io}]

set_property PULLUP true [get_ports {iic_0_scl_io}]
set_property PULLUP true [get_ports {iic_0_sda_io}]

set_property SLEW SLOW [get_ports {iic_0_scl_io}]
set_property SLEW SLOW [get_ports {iic_0_sda_io}]
