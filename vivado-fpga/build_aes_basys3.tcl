##==============================================================================
## build_aes_basys3.tcl
## One-shot Vivado flow for the pipelined AES-128 Basys 3 demo.
##
## Run from this folder (next to the rtl/ sim/ constraints/ sub-folders):
##
##   vivado -mode batch -source build_aes_basys3.tcl -tclargs sim      ;# simulate only
##   vivado -mode batch -source build_aes_basys3.tcl -tclargs build    ;# synth+impl+bitstream
##   vivado -mode batch -source build_aes_basys3.tcl -tclargs all      ;# sim then build (default)
##   vivado -mode batch -source build_aes_basys3.tcl -tclargs program  ;# program board (after build)
##
## Or from the Vivado GUI Tcl Console:   cd <folder>;  source build_aes_basys3.tcl
## (runs "all" and leaves the project open in the GUI).
##
## Output: ./vivado_proj/aes128_basys3.xpr   (open this in the GUI afterwards)
##         ./vivado_proj/reports/*.rpt
##         ./vivado_proj/aes128_basys3.runs/impl_1/PasswordManagerDemo.bit (+ .bin)
##==============================================================================

set script_dir [file dirname [file normalize [info script]]]
set proj_name  aes128_basys3
set proj_dir   [file join $script_dir vivado_proj]
set part       xc7a35tcpg236-1
set top_synth  PasswordManagerDemo
set top_sim    tb_PasswordManagerDemo
set jobs       4

set mode all
if {[info exists argv] && [llength $argv] > 0} { set mode [string tolower [lindex $argv 0]] }
if {[lsearch -exact {sim build all program} $mode] < 0} {
    error "Unknown mode '$mode'. Use: sim | build | all | program"
}

# Locate a source file either flat beside the script or in a sub-folder
proc find_src {name} {
    global script_dir
    foreach d [list "" rtl sim constraints src] {
        set p [file join $script_dir $d $name]
        if {[file exists $p]} { return [file normalize $p] }
    }
    error "Cannot find $name next to the script (or in rtl/ sim/ constraints/)"
}

proc wait_run {run} {
    if {[llength [info commands wait_on_runs]]} { wait_on_runs $run } else { wait_on_run $run }
}

#------------------------------------------------------------------------------
# Project creation (or re-open)
#------------------------------------------------------------------------------
proc make_project {} {
    global proj_name proj_dir part top_synth top_sim
    create_project $proj_name $proj_dir -part $part -force

    # Use the Digilent board file if it is installed (optional)
    set bp [get_board_parts -quiet -latest_file_version {*basys3*}]
    if {[llength $bp] > 0} {
        set_property board_part [lindex $bp 0] [current_project]
        puts "INFO: using board part [lindex $bp 0]"
    }
    set_property target_language Verilog [current_project]
    set_property simulator_language Mixed [current_project]

    add_files -norecurse -fileset sources_1 [list \
        [find_src aes_pkg.v] \
        [find_src aes_round_function.v] \
        [find_src aes_encrypt_128_pipeline.v] \
        [find_src PasswordManagerFPGA.sv] \
        [find_src PasswordManagerDemo.sv] ]
    add_files -norecurse -fileset constrs_1 [find_src PasswordManagerFPGA.xdc]
    add_files -norecurse -fileset sim_1     [find_src tb_PasswordManagerDemo.sv]

    set_property file_type SystemVerilog [get_files *.sv]
    set_property top $top_synth [get_filesets sources_1]
    set_property top $top_sim   [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]
    # Test finishes at ~4.5 us; $finish stops it, 20 us is a safety ceiling
    set_property -name {xsim.simulate.runtime} -value {20us} -objects [get_filesets sim_1]
    set_property -name {xsim.simulate.log_all_signals} -value {true} -objects [get_filesets sim_1]

    # Also write a .bin for programming the on-board QSPI flash
    set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]

    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1
}

#------------------------------------------------------------------------------
# Behavioural simulation with pass/fail check
#------------------------------------------------------------------------------
proc do_sim {} {
    global proj_dir proj_name
    launch_simulation -simset sim_1 -mode behavioral
    set log [file join $proj_dir $proj_name.sim sim_1 behav xsim simulate.log]
    set txt ""
    if {[file exists $log]} { set fh [open $log r]; set txt [read $fh]; close $fh }
    if {[regexp {TEST PASSED[^\n]*} $txt m]} {
        puts "\n================ SIMULATION: $m ================\n"
    } else {
        regexp {TEST FAILED[^\n]*} $txt m
        if {![info exists m]} { set m "no PASS/FAIL line found - see $log" }
        error "SIMULATION FAILED: $m"
    }
    catch {close_sim -force}
}

#------------------------------------------------------------------------------
# Synthesis -> implementation -> bitstream, with timing gate
#------------------------------------------------------------------------------
proc do_build {} {
    global proj_dir jobs
    file mkdir [file join $proj_dir reports]

    reset_run synth_1
    launch_runs synth_1 -jobs $jobs
    wait_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "Synthesis failed - see synth_1/runme.log" }

    launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    wait_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "Implementation failed - see impl_1/runme.log" }

    open_run impl_1
    set rdir [file join $proj_dir reports]
    report_timing_summary -max_paths 10 -file [file join $rdir timing_summary.rpt]
    report_utilization -hierarchical          -file [file join $rdir utilization_hier.rpt]
    report_utilization                         -file [file join $rdir utilization.rpt]
    report_drc                                 -file [file join $rdir drc.rpt]
    report_methodology                         -file [file join $rdir methodology.rpt]

    set wns [get_property STATS.WNS [get_runs impl_1]]
    set whs [get_property STATS.WHS [get_runs impl_1]]
    puts "\n================ TIMING: WNS = $wns ns   WHS = $whs ns ================"
    if {$wns < 0 || $whs < 0} {
        puts "WARNING: timing NOT met - see reports/timing_summary.rpt"
    } else {
        puts "Timing met at 100 MHz."
    }
    puts "Bitstream: [glob -nocomplain [file join $proj_dir *.runs impl_1 *.bit]]\n"
}

#------------------------------------------------------------------------------
# Program the FPGA over USB-JTAG (volatile: lost on power-off)
#------------------------------------------------------------------------------
proc do_program {} {
    global proj_dir top_synth
    set bit [lindex [glob -nocomplain [file join $proj_dir *.runs impl_1 $top_synth.bit]] 0]
    if {$bit eq ""} { error "No bitstream found - run the 'build' step first" }
    open_hw_manager
    connect_hw_server -allow_non_jtag
    open_hw_target
    set dev [lindex [get_hw_devices xc7a35t*] 0]
    if {$dev eq ""} { error "No xc7a35t found on the JTAG chain - is the Basys 3 plugged in and powered?" }
    current_hw_device $dev
    refresh_hw_device -update_hw_probes false $dev
    set_property PROGRAM.FILE $bit $dev
    program_hw_devices $dev
    puts "\n================ PROGRAMMED $dev with $bit ================\n"
    close_hw_target
    disconnect_hw_server
    close_hw_manager
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
switch $mode {
    sim     { make_project; do_sim }
    build   { make_project; do_build }
    all     { make_project; do_sim; do_build }
    program { do_program }
}
