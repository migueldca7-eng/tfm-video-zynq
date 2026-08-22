# Simula directamente el RTL generado por la solucion HLS solution_axis.
#
# Uso desde la raiz del repositorio:
#   vivado -mode batch -source hls/video_proc/rtl_tb/run_video_filter_rtl_tb.tcl
#
# Antes de ejecutarlo debe haberse completado C Synthesis en Vivado HLS.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/../../.."]
set rtl_dir    [file normalize "$repo_root/work/video_filter_hls/solution_axis/syn/verilog"]
set sim_dir    [file normalize "$repo_root/work/video_filter_rtl_sim"]
set tb_file    [file normalize "$script_dir/tb_video_filter_rtl.sv"]

if {![file isdirectory $rtl_dir]} {
    error "Generated HLS RTL directory not found: $rtl_dir\nRun C Synthesis for solution_axis first."
}

if {![file exists "$rtl_dir/video_filter.v"]} {
    error "Generated top module not found: $rtl_dir/video_filter.v"
}

file mkdir $sim_dir

create_project -force video_filter_rtl_sim $sim_dir -part xc7z010clg400-1
set_property target_simulator XSim [current_project]

add_files -norecurse [glob -directory $rtl_dir *.v]
add_files -fileset sim_1 -norecurse $tb_file
set_property file_type SystemVerilog [get_files $tb_file]
set_property top tb_video_filter_rtl [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

launch_simulation
run all
close_sim
close_project

