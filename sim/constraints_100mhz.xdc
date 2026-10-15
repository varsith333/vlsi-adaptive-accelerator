# ============================================================================
# constraints_100mhz.xdc -- single clock domain, 100 MHz (10 ns), Arty A7
# ----------------------------------------------------------------------------
# Board (project decision, Phase 2): Arty A7-35T, default part
# xc7a35ticsg324-1L.  If you use an A7-100T board instead, change PART in
# sim/synth_impl.tcl (and this file needs no edit).
#
# All four variants (top_variant_a/b/c1/c2) share one interface, so this one
# file serves every synthesis run.
# ============================================================================
create_clock -period 10.000 -name sys_clk [get_ports clk]

# Nominal external timing budget: 2 ns max / 0 ns min on every port.  The
# board-level trace delays are outside this project's scope; these values
# make the I/O paths reportable instead of unconstrained.
set all_in  {in_a[*] in_b[*] in_valid out_ready clear_latched rst_n}
set all_out {in_ready out_result[*] out_valid mode[*] err_count[*] fault_latched protection_active}

set_input_delay  -clock sys_clk -max 2.000 [get_ports $all_in]
set_input_delay  -clock sys_clk -min 0.000 [get_ports $all_in]
set_output_delay -clock sys_clk -max 2.000 [get_ports $all_out]
set_output_delay -clock sys_clk -min 0.000 [get_ports $all_out]
