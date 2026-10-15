# MT-09: post-route power with SAIF activity annotation.
# argv: <variant> <strip_path> <saif_file_or_DEFAULT> <dcp_suffix>
#   strip_path = instance of top_variant_<v> as it appears in the SAIF file
#                (tb_top_module.h_<X>.g<X>.u_v), so SAIF subtrees map onto the
#                opened checkpoint's hierarchy (u_top/...).
set v     [lindex $argv 0]
set strip [lindex $argv 1]
set saif  [lindex $argv 2]
set sfx   [lindex $argv 3]

open_checkpoint top_variant_$v$sfx.dcp
set applied 0
if {$saif ne "DEFAULT"} {
    if {[catch {read_saif -verbose -strip_path $strip -out_file saif_unmatched_$v$sfx.txt $saif} msg]} {
        puts "SAIF_FAILED v=$v msg=$msg"
    } else {
        set applied 1
    }
}
puts "SAIF_APPLIED v=$v applied=$applied"
report_power -file power_$v$sfx.rpt
close_design
puts "POWER_DONE v=$v"
