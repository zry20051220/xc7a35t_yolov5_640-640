if {[llength $argv] != 1} { error "Expected one explicit bitstream path" }
set bit [file normalize [lindex $argv 0]]
if {![file exists $bit]} { error "Missing bitstream: $bit" }
open_hw
connect_hw_server
set target [get_hw_targets -quiet */Digilent/B1767B26ABCD]
if {[llength $target] != 1} { error "Expected the verified ACX720 JTAG target" }
current_hw_target $target
open_hw_target
set device [get_hw_devices -quiet xc7a35t_0]
if {[llength $device] != 1} { error "Expected XC7A35T device" }
current_hw_device $device
set_property PROGRAM.FILE $bit $device
program_hw_devices $device
refresh_hw_device $device
puts "PROGRAMMED=$bit"
close_hw_target
disconnect_hw_server
close_hw
