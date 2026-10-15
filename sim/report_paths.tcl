# Worst register-to-register setup paths from a routed checkpoint.
# Used to distinguish internal datapath criticality from output-pad paths
# (report_timing at top level ranks the out_result pad paths first).
# Run from the directory containing the checkpoints:
#   vivado -mode batch -source report_paths.tcl
foreach v {a b c1 c2} {
    open_checkpoint top_variant_$v.dcp
    set seq [get_cells -hier -filter {IS_SEQUENTIAL == true}]
    report_timing -delay_type max -max_paths 10 -to $seq -file timing_path2reg_$v.rpt
    close_design
}
