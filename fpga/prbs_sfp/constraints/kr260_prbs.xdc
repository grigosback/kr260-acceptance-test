# KR260 SFP+ PRBS tester constraints
# Pin sources: fpganinja/taxi src/eth/example/KR260/fpga/syn/{sfp,gpio}.xdc,
# cross-checked against the xck26-sfvc784 package (R4/T2 -> GTHE4_CHANNEL_X0Y6).

set_property BITSTREAM.GENERAL.COMPRESS true [current_design]

# SFP+ GTH (quad 224 lane 2); the GT Wizard's own XDC LOCs the channel to X0Y6
set_property PACKAGE_PIN T2 [get_ports sfp_rx_p]
set_property PACKAGE_PIN T1 [get_ports sfp_rx_n]
set_property PACKAGE_PIN R4 [get_ports sfp_tx_p]
set_property PACKAGE_PIN R3 [get_ports sfp_tx_n]

# U90 fixed 156.25 MHz oscillator -> MGTREFCLK0_224
set_property PACKAGE_PIN Y6 [get_ports sfp_mgt_refclk_p]
set_property PACKAGE_PIN Y5 [get_ports sfp_mgt_refclk_n]
create_clock -period 6.400 -name sfp_mgt_refclk [get_ports sfp_mgt_refclk_p]

# SFP sideband + LEDs
set_property -dict {PACKAGE_PIN Y10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports sfp_tx_disable]
set_property -dict {PACKAGE_PIN G8  IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {sfp_led[0]}]
set_property -dict {PACKAGE_PIN F7  IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {sfp_led[1]}]
set_property -dict {PACKAGE_PIN F8  IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN E8  IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led[1]}]
set_false_path -to [get_ports {sfp_tx_disable sfp_led[*] led[*]}]

# Clock-domain crossings: every crossing goes through cdc_sync (first stage "meta")
# or reads snapshot registers that are static once snap_ack has toggled.
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *u_sync_*/meta_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *snap_*_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *injected_reg*}] -to [get_cells -hierarchical -filter {NAME =~ *snap_injected_reg*}]
