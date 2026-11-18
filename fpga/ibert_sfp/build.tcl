# IBERT for the KR260 SFP+ cage
#
#   SFP+ cage -> GTH quad 224, lane 2 (GTHE4 TX R4/R3, RX T2/T1)
#   Reference -> U90 fixed 156.25 MHz oscillator on MGTREFCLK0_224 (Y6/Y5)
#   Line rate -> 10.3125 Gb/s (10GBASE-R), QPLL0
#
# IBERT's own logic is clocked from the same reference clock (QUAD224_0), so the
# design needs no other clock or pin. All 4 lanes of quad 224 get a PRBS
# generator/checker; only lane 2 is wired to the SFP+ cage.
#
# Pin sources: fpganinja/taxi src/eth/example/KR260/fpga/syn/sfp.xdc and
# litex-boards xilinx_kr260.py (both agree).
#
# Usage:  vivado -mode batch -source fpga/ibert_sfp/build.tcl
# Output: fpga/ibert_sfp/out/ibert_sfp.bit (+ .ltx)

set part      xck26-sfvc784-2LV-c
set here      [file normalize [file dirname [info script]]]
set build     [file join $here build]
set out       [file join $here out]
set ip_name   ibert_sfp

file delete -force $build $out
file mkdir $build $out [file join $build ip]

create_project ip_proj [file join $build ip_proj] -part $part
create_ip -vlnv xilinx.com:ip:ibert_ultrascale_gth:1.4 -module_name $ip_name -dir [file join $build ip]
set ip [get_ips $ip_name]

# Protocol 1: 10.3125 Gb/s from a 156.25 MHz reference
set_property -dict [list \
    CONFIG.C_PROTOCOL_MAXLINERATE_1      10.3125 \
    CONFIG.C_PROTOCOL_REFCLK_FREQUENCY_1 156.25 \
    CONFIG.C_PROTOCOL_DATAWIDTH_1        40 \
    CONFIG.C_PROTOCOL_PLL_1              QPLL0 \
    CONFIG.RX_COUPLING_1                 AC \
    CONFIG.RX_EQ_MODE_1                  AUTO \
] $ip

# Quad 224 uses protocol 1 and MGTREFCLK0_224; IBERT sysclk = that refclk
set quad_proto [get_property CONFIG.C_PROTOCOL_QUAD1 $ip]
if {![string match "Custom_1*10.3125*" $quad_proto]} {
    set_property CONFIG.C_PROTOCOL_QUAD1 {Custom_1_/_10.3125_Gbps} $ip
}
set_property -dict [list \
    CONFIG.C_REFCLK_SOURCE_QUAD_1 MGTREFCLK0_224 \
    CONFIG.C_SYSCLOCK_SOURCE_INT  QUAD224_0 \
] $ip

puts "IBERT config:"
foreach p {C_PROTOCOL_QUAD1 C_PROTOCOL_MAXLINERATE_1 C_PROTOCOL_REFCLK_FREQUENCY_1
           C_PROTOCOL_PLL_1 C_REFCLK_SOURCE_QUAD_1 C_SYSCLOCK_SOURCE_INT
           C_SYSCLK_FREQUENCY C_SYSCLK_MODE_EXTERNAL} {
    puts [format "  %-32s %s" $p [get_property CONFIG.$p $ip]]
}

generate_target all $ip
open_example_project -force -in_process -dir $build $ip

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set impl_dir [get_property DIRECTORY [get_runs impl_1]]
set bit [lindex [glob -nocomplain [file join $impl_dir *.bit]] 0]
set ltx [lindex [glob -nocomplain [file join $impl_dir *.ltx]] 0]
if {$bit eq ""} {
    error "No bitstream produced; see [file join $impl_dir runme.log]"
}
file copy -force $bit [file join $out ${ip_name}.bit]
if {$ltx ne ""} { file copy -force $ltx [file join $out ${ip_name}.ltx] }

open_run impl_1
report_timing_summary -file [file join $out timing_summary.rpt]
report_utilization    -file [file join $out utilization.rpt]
puts "WNS: [get_property STATS.WNS [get_runs impl_1]]  WHS: [get_property STATS.WHS [get_runs impl_1]]"
puts "BITSTREAM_OK [file join $out ${ip_name}.bit]"
