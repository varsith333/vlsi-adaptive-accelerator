# Experiment Plan

Project: Runtime-Adaptive Reliability-Aware AI Accelerator for FPGA
Part: xc7a35ticsg324-1L (Arty A7-35T), tools: Vivado 2025.2 (xsim + batch Vivado)

## 1. Research questions

- RQ1 (functionality): do the four variants (A, B, C1, C2) produce bit-exact
  golden outputs in a fault-free run, with zero false positives (MT-04 = 0)?
- RQ2 (detection/recovery): how much fault coverage (MT-01) and what
  recovery latency (MT-03) does each protection scheme deliver per fault
  class F-01..F-04?
- RQ3 (cost): what area (MT-05 LUT/FF/DSP/BRAM), timing (MT-08 WNS/Fmax),
  latency (MT-06), throughput (MT-07) and power (MT-09) does each scheme pay?
- RQ4 (trade-off): does runtime adaptation (C1/C2) approach B's protection
  (MT-01, MT-02) at lower overhead (MT-05, power)?

## 2. Configurations (single parameterized `top_module`)

| Config | Protection | MONITOR_EN | Mode policy |
|---|---|---|---|
| A | none (baseline) | 0 | always NORMAL |
| B | always-on DMR | 1 | FORCE_PROTECTED |
| C1 | adaptive DMR | 1 | NORMAL/MONITORED/PROTECTED (TH_ERR=2, TH_SEV=4) |
| C2 | adaptive temporal recompute | 1 | same policy, recompute instead of DMR |

All four share identical golden vectors; differences come only from the
protection policy (V-08).

## 3. Metric -> experiment traceability

| Metric | Experiment | Artifact |
|---|---|---|
| MT-01 detection coverage | E2 FI campaign | `reports/fi_results.csv` |
| MT-02 protection-active % | E1 golden regression | tb_top_module metrics |
| MT-03 recovery latency | E2 FI campaign | `reports/fi_results.csv` |
| MT-04 false positives | E1 golden regression | tb_top_module PASS, errors=0 |
| MT-05 overhead % | E3 synthesis | `reports/synth_results*.csv` |
| MT-06 latency | E1 golden regression | tb_top_module metrics |
| MT-07 throughput | E1 golden regression | tb_top_module metrics |
| MT-08 WNS/Fmax | E3 implementation | `reports/timing_*.rpt` |
| MT-09 power (SAIF) | E4 power | `reports/power_*.rpt` (see note) |

## 4. E1 - golden regression (V-06, RQ1)

Method: `sim\run_sim.ps1 -Tb tb_top_module`. 1200 deterministic vectors per
variant (fixed seed 0xDEADBEEF), expected-value FIFO scoreboard pops at every
`out_valid`; any mismatch or SVA failure fails the run. Directed
transition/injection tests inside the same run exercise T-1, T-2b, T-3, T-6,
T-7, T-8, parity detection latency (V-04), gross-corruption recovery.

Acceptance: PASS with errors = 0 (includes `herrors` from all four SVA
guards) => MT-04 = 0.

## 5. E2 - fault-injection campaign (V-07, RQ2)

Matrix: 4 configs x {F-01, F-02, F-03, F-04} x seeds {1..5} x 1000
injections = 80 runs = 80,000 single-fault injections (spec minimum was
20,000/config; we ran the full 4-class x 5-seed matrix per config).

Protocol per injection (one fault per reset):
1. RESET, warmup >= 100 cycles and >= 5 committed outputs (active window).
2. LFSR gap of 20-120 cycles (Galois LFSR, tap 0xA3000000, seed =
   `SEED * 0x9E3779B9 | 1`, logged in every CSV row).
3. Deposit at negedge (full cycle of corruption), class-dependent target:
   F-01 accumulator XOR, F-02 output-buffer head entry, F-03 stored operand
   (input buffer for A; checkpoint for B/C1/C2), F-04 force FSM state.
4. Observation: settle / 350-cycle liveness limit (wd window is 256) /
   600-cycle cap, then classification:
   `noplace | hang | wrong | detected | detected_wrong | masked`.
5. Next run. Faults are permanent-for-that-run (F-02/F-03) or a single-cycle
   deposit (F-01/F-04) per spec rules.

Aggregation: `sim\run_fi.ps1` -> `reports/fi_results.csv` (+ `.md`),
row-level `reports/fi_raw.csv`, run log `build/fi_log.csv`.
MT-01 = 100 * flagged-before-wrong / valid injections (per cell).
MT-03 = flag -> first correct committed output after recovery (avg).
Run parameters reach the TB via `build/fi_args.txt` (xsim plusarg `=`-split
workaround).

## 6. E3 - synthesis and implementation (RQ3)

Flow: non-project batch Vivado (`sim/synth_impl.tcl`) - read_verilog (mixed
SV), constraints, `synth_design`, `opt_design/place/route`, then
`report_utilization`, `report_timing_summary`, `report_timing -max_paths 10`,
`report_drc`, checkpoint. Driven by `sim/run_synth.ps1 -PeriodTag <100|75>`
with staging into a space-free temp workspace (Vivado file commands truncate
paths at spaces - see verification_plan.md deviation 3).

Two constraint sets, both reported transparently:
- `sim/constraints_100mhz.xdc` (10 ns): design characterization at the
  original target; measured WNS is negative on all variants, so this is
  reported as a characterization run, not a signoff claim. Measured critical
  paths (`reports/timing_path_*.rpt`, `reports/timing_path2reg_*.rpt`): the
  overall WNS path is the output interface (output-buffer register ->
  `out_result` pad, 2 ns external output delay, OBUF 2.64 ns, clock insertion
  delay 4.66 ns); the worst internal register-to-register path is input-buffer
  read -> MAC accumulate -> parity XOR in one cycle with a LUT-mapped
  multiplier (DSP = 0): slack at 10 ns = -0.587 (A), -2.578 (B), -2.561 (C1),
  -2.781 (C2) ns - the protection variants' parity/compare logic roughly
  quadruples the internal violation.
- `sim/constraints_75mhz.xdc` (13.333 ns): signoff run - MT-08 requires
  post-impl WNS >= 0; Fmax = 1/(period - WNS) is computed from the
  characterization run's negative-WNS data as Fmax = 1/(period + |WNS|).

Per-variant artifacts: `reports/util_<v>.rpt`, `timing_<v>.rpt`,
`timing_path_<v>.rpt` (critical path name), `drc_<v>.rpt`, checkpoints in
`build/`, summary `synth_results*.csv/md`. MT-05 =
`100*(v - A)/A` for LUT/FF/each resource.

## 7. E4 - power (MT-09)

Primary method (spec): gate-level-ish activity - store SAIF from an xsim run
of the golden fixed trace (tcl `open_saif` / `log_saif [get_objects -r *]` /
`close_saif`, elaborate with `-debug all`), then `read_saif -strip_path
tb_top_module/h_<v>.g<v>.u_v` + `report_power` on the routed `_p75`
checkpoint. As executed, SAIF capture succeeded but post-synthesis net-name
absorption limits annotation coverage to 7-12% of nets (measured, logged
per variant in `build/vivado_power_<v>_p75.out`); the report discloses the
annotated percentage for every row, and a `-DefaultActivity` comparison run
is reported alongside as `power_results_p75_default.csv` - never presented
as SAIF numbers.

## 8. Reproducibility (from project root)

```powershell
powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1 -Tb <tb_name>   # unit/top tests
powershell -ExecutionPolicy Bypass -File sim\run_fi.ps1                  # 80-run FI campaign
powershell -ExecutionPolicy Bypass -File sim\run_synth.ps1 -PeriodTag 100
powershell -ExecutionPolicy Bypass -File sim\run_synth.ps1 -PeriodTag 75
```

## 9. Threats to validity / limitations

1. RTL simulation, not gate-level FI: faults are deposited on modeled
   signals; SEU-sensitive node mapping to actual bitstreams is out of scope.
2. F-02 lands after commit by construction, so MT-01 for that class measures
   flag-at-delivery, not flag-before-corruption (documented in
   verification_plan.md section 6).
3. Single active clock domain, no CDC; conclusions do not transfer to
   multi-clock designs.
4. 100 MHz signoff failed: the overall critical path is the output interface
   (register -> `out_result` pad with 2 ns output delay), while the worst
   internal path is the input-buffer -> accumulate -> parity recurrence with a
   LUT-mapped multiplier (DSP = 0; see section 6); the 75 MHz run is the
   timing signoff. A DSP-inferred pipelined MAC and a registered/pipelined
   output interface are the obvious future fixes, deliberately not done
   post-freeze.
5. Power numbers depend on the activity source and on annotation coverage:
   SAIF rows disclose the 7-12% annotated fraction (the rest uses Vivado's
   probabilistic defaults); the default-activity run is reported separately.
