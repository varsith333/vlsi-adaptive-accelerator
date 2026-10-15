# Synthesis + implementation results (Phase 8)

Part: xc7a35ticsg324-1L (Arty A7-35T), constraint tag 100,
non-project batch flow, post-route numbers.

| variant | period (ns) | LUT | FF | BRAM | DSP | WNS (ns) | TNS (ns) | critical path (ns) | max freq (MHz) | critical path from | to |
|---|---|---|---|---|---|---|---|---|---|---|---|
| a | 10 | 294 | 480 | 0 | 0 | -2.806 | -92.007 | 12.806 | 78.1 | u_top/u_obuf/rptr_reg[1]/C | out_result[2] |
| b | 10 | 609 | 643 | 0 | 0 | -2.97 | -144.043 | 12.97 | 77.1 | u_top/u_obuf/rptr_reg[1]/C | out_result[17] |
| c1 | 10 | 648 | 655 | 0 | 0 | -2.952 | -143.265 | 12.952 | 77.2 | u_top/u_obuf/rptr_reg[0]/C | out_result[22] |
| c2 | 10 | 534 | 662 | 0 | 0 | -2.992 | -117.279 | 12.992 | 77 | u_top/u_obuf/rptr_reg[1]/C | out_result[1] |

WNS/TNS from post-route setup analysis; max freq = 1000 / critical path delay.
Detailed reports: reports/util_<v>.rpt, reports/timing_<v>.rpt, reports/timing_path_<v>.rpt, reports/drc_<v>.rpt.
