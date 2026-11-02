# TD 6.2.168116 command-line build. Run using td_commands_prompt.exe.
# The two directory junctions described in README.md must already exist.
set project_dir [file normalize [file join [file dirname [info script]] ..]]
set output_dir [file join $project_dir build]
file mkdir $output_dir
cd [file join $project_dir td_project]
set result_base [file join $output_dir Emergency_Display_Baseline]

if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project Emergency_Display_Baseline.al -single_run
    load_run_param -run syn_1
    elaborate -top emergency_display_top
    read_adc ../constraints/pin.adc
    read_sdc ../constraints/timing.sdc
    read_sdc -ip rfifo_32_32_512 ../user_source/hdl_source/IP/afifo_32_16_256.tcl
    commit_param -step rtl
    optimize_rtl
    set_param gate eram_init on
    commit_param -step gate
    optimize_gate -packarea ${result_base}_gate.area
    legalize_phy_inst
    update_timing
    report_timing_summary -file ${result_base}_gate.timing
    export_db ${result_base}_gate.db
    commit_param -step place
    # Storage-domain paths sit within a few 100 ps of 8 ns; timing-driven placement at high
    # effort (TD defaults: medium) gives repeatable closure. Same parameters as the GUI.
    set_param place effort high
    set_param place opt_timing high
    place
    commit_param -step route
    route
    # Post-route hold repair, as in TD's doc/scripts/DefaultFlow.tcl (drHoldFix). At about
    # 79 % LUT the router left a few register -> BRAM address hold paths at -0.01..-0.05 ns
    # (2026-11-02, cross-fade build); fix_hold inserts delay on those nets only.
    fix_hold
    update_timing -mode final
    report_timing_summary -file ${result_base}_route.timing
    report_timing_status -file ${result_base}_route.ts
    report_timing_exception -file ${result_base}_exception.timing
    report_area -io_info -file ${result_base}_route.area
    export_db ${result_base}_route.db
    commit_param -step bitgen
    bitgen -bit ${result_base}.bit
} build_error]} {
    puts stderr "BUILD_FAILED: $build_error"
    exit 1
}
# A generated bitstream is not proof of timing closure or board operation.
puts "BUILD_FINISHED_REVIEW_TIMING_AND_TEST_BOARD"
exit 0
