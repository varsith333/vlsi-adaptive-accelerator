# Synthesis + implementation results (Phase 8)

Part: xc7a35ticsg324-1L (Arty A7-35T), constraint tag 75,
non-project batch flow, post-route numbers.

| variant | period (ns) | LUT | FF | BRAM | DSP | WNS (ns) | TNS (ns) | critical path (ns) | max freq (MHz) | critical path from | to |
|---|---|---|---|---|---|---|---|---|---|---|---|
| a | 13.333 | 291 | 480 | 0 | 0 | 0.166 | 0 | 13.167 | 75.9 | u_top/u_obuf/mem_reg[2][29]/C | out_result[29] |
| b | 13.333 | 582 | 643 | 0 | 0 | 0.067 | 0 | 13.266 | 75.4 | u_top/u_obuf/mem_reg[2][1]/C | out_result[1] |
| c1 | 13.333 | 621 | 655 | 0 | 0 | 0.017 | 0 | 13.316 | 75.1 | u_top/u_ibuf/rptr_reg[1]/C | u_top/u_core/u_lane_a/acc_parity_reg/D |
| c2 | 13.333 | 532 | 662 | 0 | 0 | 0.066 | 0 | 13.267 | 75.4 | u_top/u_ibuf/rptr_reg[1]/C | u_top/u_core/u_lane_a/acc_parity_reg/D |

WNS/TNS from post-route setup analysis; max freq = 1000 / critical path delay.
Detailed reports: reports/util_<v>.rpt, reports/timing_<v>.rpt, reports/timing_path_<v>.rpt, reports/drc_<v>.rpt.
