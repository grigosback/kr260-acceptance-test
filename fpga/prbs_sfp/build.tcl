# Build the KR260 SFP+ PRBS tester (free IP only: GT Wizard + Zynq UltraScale+ PS)
#
# Usage:  vivado -mode batch -source fpga/prbs_sfp/build.tcl
# Output: fpga/prbs_sfp/out/kr260-prbs.bit, kr260-prbs.bit.bin (for xmutil/fpga_manager),
#         timing + utilisation reports

set part    xck26-sfvc784-2LV-c
set here    [file normalize [file dirname [info script]]]
set build   [file join $here build]
set out     [file join $here out]
set app     kr260-prbs

file delete -force $build $out
file mkdir $build $out [file join $build ip]

create_project prj [file join $build prj] -part $part
set_property target_language Verilog [current_project]
add_files [glob [file join $here rtl *.v]]
add_files -fileset constrs_1 [file join $here constraints kr260_prbs.xdc]

# ------------------------------------------------------------------ GT Wizard
create_ip -vlnv xilinx.com:ip:gtwizard_ultrascale:1.7 -module_name gt_sfp -dir [file join $build ip]
set gt [get_ips gt_sfp]
set_property -dict [list \
    CONFIG.CHANNEL_ENABLE          X0Y6 \
    CONFIG.TX_MASTER_CHANNEL       X0Y6 \
    CONFIG.RX_MASTER_CHANNEL       X0Y6 \
    CONFIG.TX_LINE_RATE            10.3125 \
    CONFIG.RX_LINE_RATE            10.3125 \
    CONFIG.TX_REFCLK_FREQUENCY     156.25 \
    CONFIG.RX_REFCLK_FREQUENCY     156.25 \
    CONFIG.TX_PLL_TYPE             QPLL0 \
    CONFIG.RX_PLL_TYPE             QPLL0 \
    CONFIG.TX_DATA_ENCODING        RAW \
    CONFIG.RX_DATA_DECODING        RAW \
    CONFIG.TX_USER_DATA_WIDTH      64 \
    CONFIG.TX_INT_DATA_WIDTH       32 \
    CONFIG.RX_USER_DATA_WIDTH      64 \
    CONFIG.RX_INT_DATA_WIDTH       32 \
    CONFIG.RX_COUPLING             AC \
    CONFIG.RX_EQ_MODE              AUTO \
    CONFIG.FREERUN_FREQUENCY       100 \
    CONFIG.LOCATE_TX_USER_CLOCKING CORE \
    CONFIG.LOCATE_RX_USER_CLOCKING CORE \
] $gt
set_property CONFIG.ENABLE_OPTIONAL_PORTS \
    {txprbssel_in rxprbssel_in rxprbserr_out rxprbslocked_out rxprbscntreset_in txprbsforceerr_in} $gt
generate_target all $gt
create_ip_run $gt

# ------------------------------------------------------------------ PS block design
# Only the PL side of this BD matters: the PS itself is configured by the Kria
# boot firmware, which sets HPM0_FPD to 128 bits (AFI_FS = 0xA00) and pl_clk0 to 100 MHz.
create_bd_design ps_bd
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps]
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0              1 \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH         128 \
    CONFIG.PSU__USE__M_AXI_GP1              0 \
    CONFIG.PSU__USE__M_AXI_GP2              0 \
    CONFIG.PSU__FPGA_PL0_ENABLE             1 \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ 100 \
    CONFIG.PSU__NUM_FABRIC_RESETS           1 \
] $ps

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst]
set sc  [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc]
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1] $sc

set m_axi [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI]
set_property -dict [list \
    CONFIG.PROTOCOL   AXI4LITE \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.ADDR_WIDTH 32 \
    CONFIG.FREQ_HZ    [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ $ps]000000 \
] $m_axi
create_bd_port -dir O -type clk pl_clk0
create_bd_port -dir O -type rst aresetn
set_property CONFIG.ASSOCIATED_BUSIF M_AXI [get_bd_ports pl_clk0]
set_property CONFIG.ASSOCIATED_RESET aresetn [get_bd_ports pl_clk0]

connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins ps/maxihpm0_fpd_aclk] \
    [get_bd_pins rst/slowest_sync_clk] [get_bd_pins sc/aclk] [get_bd_ports pl_clk0]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst/ext_reset_in]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins sc/aresetn] [get_bd_ports aresetn]
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc/M00_AXI] $m_axi

assign_bd_address -offset 0xA0000000 -range 64K [get_bd_addr_segs M_AXI/Reg]
validate_bd_design
save_bd_design
set wrapper [make_wrapper -files [get_files ps_bd.bd] -top]
add_files $wrapper
generate_target all [get_files ps_bd.bd]

set_property top kr260_prbs_top [current_fileset]
update_compile_order -fileset sources_1

# ------------------------------------------------------------------ implementation
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation failed; see [get_property DIRECTORY [get_runs impl_1]]/runme.log"
}

set impl_dir [get_property DIRECTORY [get_runs impl_1]]
file copy -force [file join $impl_dir kr260_prbs_top.bit] [file join $out $app.bit]

open_run impl_1
report_timing_summary -file [file join $out timing_summary.rpt]
report_utilization    -file [file join $out utilization.rpt]
report_cdc            -file [file join $out cdc.rpt]
set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
puts "WNS: $wns  WHS: $whs"

# .bit -> .bit.bin for the Linux FPGA manager
set bif [file join $build $app.bif]
set fh [open $bif w]
puts $fh "all:\n{\n  \[destination_device = pl\] [file join $out $app.bit]\n}"
close $fh
exec bootgen -image $bif -arch zynqmp -process_bitstream bin -w -o [file join $out $app.bit.bin] >@ stdout
# bootgen writes <bit>.bin next to the .bit regardless of -o in some releases
if {![file exists [file join $out $app.bit.bin]]} {
    error "bootgen did not produce $app.bit.bin"
}
puts "BITSTREAM_OK [file join $out $app.bit.bin]  WNS=$wns WHS=$whs"
