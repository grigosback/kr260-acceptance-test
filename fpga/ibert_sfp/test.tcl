# Program the KR260 over JTAG with the IBERT bitstream and run the SFP+ loopback test.
#
# Usage: vivado -mode batch -source fpga/ibert_sfp/test.tcl -tclargs [seconds] [scan]
#   seconds : PRBS31 soak time per run (default 300 -> ~3.1e12 bits at 10.3125 Gb/s,
#             0 errors => BER < 1e-12 at 95% confidence)
#   scan    : "scan" to also run a 2D statistical eye scan on the locked lane(s)
#
# Before running: unload the board's PL app (sudo xmutil unloadapp) and insert the
# SFP+ loopback module. A TX->RX link is created on every lane of quad 224; only
# the lane wired to the SFP+ cage (lane 2) is expected to lock.

set seconds [expr {[llength $argv] > 0 ? [lindex $argv 0] : 300}]
set do_scan [expr {[lsearch $argv scan] >= 0}]
set here    [file normalize [file dirname [info script]]]
set out     [file join $here out]
set bit     [file join $out ibert_sfp.bit]
set stamp   [clock format [clock seconds] -format %Y%m%d-%H%M%S]
set results [file join [file dirname [file dirname $here]] results ibert_sfp_$stamp]
file mkdir $results

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xck26*] 0]
if {$dev eq ""} { error "No xck26 device found on the JTAG chain: [get_hw_devices]" }
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
set_property PROBES.FILE {} $dev
program_hw_devices $dev
refresh_hw_device $dev

set gts [get_hw_sio_gts]
puts "GTs: $gts"
foreach gt $gts {
    create_hw_sio_link -description "[lindex [split $gt /] end]" \
        [lindex [get_hw_sio_txs -of_objects $gt] 0] [lindex [get_hw_sio_rxs -of_objects $gt] 0]
}
set links [get_hw_sio_links]

proc show {links label} {
    puts "---- $label"
    foreach l $links {
        puts [format "  %-14s status=%-12s bits=%-14s errors=%-8s BER=%s" \
            [get_property DESCRIPTION $l] [get_property STATUS $l] \
            [get_property RX_RECEIVED_BIT_COUNT $l] [get_property LOGIC.ERRBIT_COUNT $l] \
            [get_property RX_BER $l]]
    }
}

set_property TX_PATTERN {PRBS 31-bit} $links
set_property RX_PATTERN {PRBS 31-bit} $links
commit_hw_sio $links
# Reset the RX datapath, then clear the error counters
set_property PORT.GTRXRESET 1 $links
commit_hw_sio $links
set_property PORT.GTRXRESET 0 $links
commit_hw_sio $links
after 2000
set_property LOGIC.MGT_ERRCNT_RESET_CTRL 1 $links
commit_hw_sio $links
set_property LOGIC.MGT_ERRCNT_RESET_CTRL 0 $links
commit_hw_sio $links
refresh_hw_sio $links
show $links "after reset"
report_property [lindex $links 0] -file [file join $results link_properties.txt]

set locked {}
foreach l $links {
    if {![string match -nocase "*no link*" [get_property STATUS $l]]} { lappend locked $l }
}
puts "Locked links: [llength $locked] of [llength $links]"

set t0 [clock seconds]
while {[clock seconds] - $t0 < $seconds} {
    after 30000
    refresh_hw_sio $links
    show $links "t=[expr {[clock seconds] - $t0}]s"
}
refresh_hw_sio $links
show $links "final"

set fh [open [file join $results summary.txt] w]
puts $fh "KR260 SFP+ IBERT loopback, $stamp, PRBS31, ${seconds}s"
foreach l $links {
    puts $fh [format "%s status=%s bits=%s errors=%s BER=%s" \
        [get_property DESCRIPTION $l] [get_property STATUS $l] \
        [get_property RX_RECEIVED_BIT_COUNT $l] [get_property LOGIC.ERRBIT_COUNT $l] \
        [get_property RX_BER $l]]
}
close $fh

if {$do_scan} {
    foreach l $locked {
        set rx [lindex [get_hw_sio_rxs -of_objects $l] 0]
        set name [get_property DESCRIPTION $l]
        set scan [create_hw_sio_scan -description "eye_$name" 2d_full_eye $rx]
        set_property HORIZONTAL_INCREMENT 2 $scan
        set_property VERTICAL_INCREMENT 2 $scan
        set_property DWELL_BER 1e-7 $scan
        run_hw_sio_scan $scan
        wait_on_hw_sio_scan $scan
        write_hw_sio_scan -force [file join $results eye_$name.csv] $scan
        report_property $scan -file [file join $results eye_${name}_properties.txt]
        puts "Eye scan $name written"
    }
}
puts "RESULTS_DIR $results"
