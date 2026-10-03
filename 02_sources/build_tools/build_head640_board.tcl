set root [file normalize [file join [file dirname [info script]] ..]]
set generated [file join $root outputs/head_training/qat_board_candidate640_v1/board]
set checkout [file join $root work/board_head_qat640]
set xpr [file join $checkout head_qat640.xpr]
set repo [file join $root hls/npu_head640_prj/solution1/impl/ip]
if {[llength $argv]} {
    if {$argv ne "store4" && $argv ne "ft" && $argv ne "upwords"} {error "Expected explicit store4, ft or upwords candidate"}
    set generated [file join $root outputs/head_training/qat_board_candidate640_store4_v1/board]
    set checkout [file join $root work/board_head_qat640_store4]
    set xpr [file join $checkout head_qat640_store4.xpr]
    set repo [file join $root hls/npu_head640_store4_prj/solution1/impl/ip]
    if {$argv eq "ft"} {
        set generated [file join $root outputs/head_training/qat_board_candidate640_ft_v1/board]
        set checkout [file join $root work/board_head_qat640_ft]
        set xpr [file join $checkout head_qat640_ft.xpr]
    }
    if {$argv eq "upwords"} {
        set generated [file join $root outputs/head_training/qat_board_candidate640_upwords_v1/board]
        set checkout [file join $root work/board_head_qat640_upwords]
        set xpr [file join $checkout head_qat640_upwords.xpr]
        set repo [file join $root hls/npu_head640_upwords_prj/solution1/impl/ip]
    }
}
if {![file exists [file join $repo component.xml]]} {error "640 IP export is required first"}
if {![file exists $xpr]} {
    open_project [file join $root work/board_head_qat320/head_qat320.xpr]
    save_project_as [file rootname [file tail $xpr]] $checkout
    close_project
}
open_project $xpr
foreach ipfile [get_files -of_objects [get_ips yolo_npu_conv]] {
    if {[file extension $ipfile] eq ".xci" && ![string match "${checkout}/*" [file normalize $ipfile]]} {
        error "Candidate IP is not isolated: $ipfile"
    }
}
set_property ip_repo_paths [list $repo] [current_project]
update_ip_catalog
upgrade_ip [get_ips yolo_npu_conv]
generate_target all [get_ips yolo_npu_conv] -force
set_property verilog_define {NPU_REALTIME320} [get_filesets sources_1]
# NPU_REALTIME320 selects the legacy transport branch; scoped copies below use 640 constants.
foreach name {acx720_yolo_board_top.v fifo2mig_axi.v yolo_packet_parser.v npu_realtime320_launcher.v} {
    set old [get_files -quiet *$name]
    if {[llength $old]} {remove_files $old}
    if {$name eq "npu_realtime320_launcher.v"} {set new [file join $generated $name]} else {set new [file join $generated rtl $name]}
    if {![file exists $new]} {error "Missing candidate source: $new"}
    add_files -norecurse $new
}
update_compile_order -fileset sources_1
foreach run [get_runs -quiet *yolo_npu_conv*synth*] {reset_run $run}
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "640 board synthesis failed"}
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "640 board implementation failed"}
open_run impl_1
report_timing_summary -file [file join $generated timing.rpt]
report_utilization -file [file join $generated utilization.rpt]
report_drc -file [file join $generated drc.rpt]
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {![llength $setup] || ![llength $hold]} {error "Missing timing paths"}
if {[get_property SLACK $setup] < 0 || [get_property SLACK $hold] < 0} {error "Timing failed: must not program"}
set bit [file join $generated head_qat640_candidate.bit]
if {[file exists $bit]} {error "Refusing to overwrite candidate bit"}
write_bitstream $bit
puts "HEAD640_CANDIDATE_BIT=$bit"
close_project
exit
