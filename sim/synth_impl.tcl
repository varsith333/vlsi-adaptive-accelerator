# ============================================================================
# synth_impl.tcl -- Phase 8: synthesis + implementation of ONE variant
# ----------------------------------------------------------------------------
# Non-project batch flow (UG835).  Invoked as:
#   vivado -mode batch -source synth_impl.tcl -tclargs <a|b|c1|c2> [ptag]
#   ptag = "100" (default): constraints_100mhz.xdc, files suffixed normally
#   ptag = "75":            constraints_75mhz.xdc,  files suffixed "_p75"
#
# Flow: read all 14 RTL files -> constraints -> synth_design -> opt -> place
#       -> route -> reports (utilization, timing, path detail) -> checkpoint.
# A machine-readable line is printed to the console:
#   SYNTH_SUM variant=<v> ptag=<p> lut=<n> ff=<n> bram=<n> dsp=<n> wns=<n>
#             tns=<n> dpath=<ns> crit_from=<cell> crit_to=<cell>
# ============================================================================
set variant [lindex $argv 0]
if {$variant eq ""} { set variant "a" }
set ptag [lindex $argv 1]
if {$ptag eq ""} { set ptag "100" }
set sfx ""
if {$ptag ne "100"} { set sfx "_p$ptag" }
# clock period corresponding to the tag (ns); critical path delay = period - slack
if {$ptag eq "75"} { set period 13.333 } else { set period 10.0 }

# Default part: Arty A7-35T (project decision, Phase 2).  A7-100T -> change here.
set part "xc7a35ticsg324-1L"

set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ..]]
set rtl  [file join $root rtl]
set rep  [file join $root reports]
set bld  [file join $root build]
file mkdir $rep
file mkdir $bld

# ------------------------------- read RTL ----------------------------------
# Full list (same order as run_sim.ps1) so every hierarchy resolves.
set rtl_files {mac_unit input_buffer output_buffer accelerator_core \
               reliability_monitor error_counter fault_detector \
               adaptive_controller recovery_controller top_module \
               top_variant_a top_variant_b top_variant_c1 top_variant_c2}
foreach f $rtl_files {
    read_verilog -sv [file join $rtl "$f.sv"]
}
if {$ptag eq "75"} {
    read_xdc [file join $here constraints_75mhz.xdc]
} else {
    read_xdc [file join $here constraints_100mhz.xdc]
}

# ------------------------------ synthesis ----------------------------------
set top "top_variant_$variant"
puts "INFO: synthesizing $top for $part"
synth_design -top $top -part $part
opt_design
place_design
route_design

# -------------------------------- reports ----------------------------------
report_utilization    -file [file join $rep "util_$variant$sfx.rpt"]
report_timing_summary -delay_type max -max_paths 20 \
                      -file [file join $rep "timing_$variant$sfx.rpt"]
report_timing         -delay_type max -max_paths 3 \
                      -file [file join $rep "timing_path_$variant$sfx.rpt"]
report_drc            -file [file join $rep "drc_$variant$sfx.rpt"]
write_checkpoint -force [file join $bld "$top$sfx.dcp"]

# -------------------- machine-readable summary line ------------------------
proc row_value {rpt pat} {
    # first capture group of the first regex match in the report file
    set fh [open $rpt r]
    set txt [read $fh]
    close $fh
    if {[regexp $pat $txt -> val]} {
        return [string map {, ""} $val]   ;# strip thousands separators
    }
    return "NA"
}
set urpt [file join $rep "util_$variant$sfx.rpt"]
# report_utilization rows may carry a footnote '*' after the label
set lut  [row_value $urpt {\|\s*Slice LUTs\*?\s*\|\s*([0-9\.,]+)\s*\|}]
set ff   [row_value $urpt {\|\s*Slice Registers\s*\|\s*([0-9\.,]+)\s*\|}]
set bram [row_value $urpt {\|\s*Block RAM Tile\s*\|\s*([0-9\.,]+)\s*\|}]
set dsp  [row_value $urpt {\|\s*DSPs\s*\|\s*([0-9\.,]+)\s*\|}]

# endpoints of the worst setup path (path-detail report)
set prpt [file join $rep "timing_path_$variant$sfx.rpt"]
set cfrom [row_value $prpt {(?:Source|From):\s*(\S+)}]
set cto   [row_value $prpt {(?:Destination|To):\s*(\S+)}]

# worst setup slack (WNS) and total negative slack over failing paths
set wpath [get_timing_paths -max_paths 1]
set wns   [get_property SLACK $wpath]
set tns_v 0.0
foreach p [get_timing_paths -max_paths 1000 -slack_lesser_than 0] {
    set tns_v [expr {$tns_v + [get_property SLACK $p]}]
}
set dpath [expr {$period - $wns}]   ;# critical path delay = period - slack

puts "SYNTH_SUM variant=$variant ptag=$ptag lut=$lut ff=$ff bram=$bram dsp=$dsp wns=$wns tns=$tns_v dpath=$dpath crit_from=$cfrom crit_to=$cto"
puts "SYNTH_DONE variant=$variant ptag=$ptag"
