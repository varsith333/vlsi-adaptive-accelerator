# ============================================================================
# run_unit.tcl — Compile RTL + one testbench, elaborate, run to completion
# Usage (from vlsi-adaptive-accelerator/build):
#   vivado -mode batch -source ..\sim\run_unit.tcl -tclargs tb_mac_unit
# ============================================================================
set tb [lindex $argv 0]
set rtl_dir "../rtl"
set tb_dir  "../tb"

set rtl_files [list \
    mac_unit input_buffer output_buffer accelerator_core \
    reliability_monitor error_counter fault_detector \
    adaptive_controller recovery_controller top_module \
    top_variant_a top_variant_b top_variant_c1 top_variant_c2]

# --- analyze RTL (timescale directives now live in the files)
foreach f $rtl_files {
    exec xvlog --sv [file join $rtl_dir "$f.sv"]
}
# --- analyze testbench
exec xvlog --sv [file join $tb_dir "$tb.sv"]

# --- elaborate & run
exec xelab $tb -s "${tb}_snap"
exec xsim "${tb}_snap" -R
