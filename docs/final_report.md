# Final Report — Runtime-Adaptive Reliability-Aware AI Accelerator for FPGA

Date: 2026-09-28
Toolchain: AMD Vivado 2025.2 (xvlog / xelab / xsim / batch Vivado)
Target: xc7a35ticsg324-1L (Digilent Arty A7-35T), single clock `sys_clk`
Status: all nine phases executed; every number below is measured from a run
on this machine, not estimated.

> **How to read this report (beginner note).** Each results section starts with
> a short explanation of *what the numbers mean* before showing them. If you are
> new to VLSI: "LUT/FF" are the FPGA's logic cells, "WNS" is how much margin the
> fastest signal has against the clock period (negative = too slow), and a
> "fault injection campaign" is a loop that deliberately corrupts one bit at a
> time to see whether the design notices.

---

## 1. Executive summary

Four variants of an INT8 dot-product (MAC) engine were built from one
parameterized RTL stack and compared on the same golden workload:

| Variant | Protection | Idea |
|---|---|---|
| **A** | none | unprotected baseline (0% protection cost reference) |
| **B** | always-on DMR | two lanes compute the same thing, results compared every cycle |
| **C1** | adaptive DMR | DMR only switched on when the error counter escalates |
| **C2** | adaptive temporal recompute | recompute and compare instead of a second lane |

Headline measured results:

- **Functionality:** all 7 testbenches PASS; top regression PASS on 4 × 1200
  golden vectors with **0 mismatches and 0 assertion failures** (MT-04 = 0 false
  positives).
- **Fault injection:** 4 configs × 4 fault classes × 5 seeds × 1000 = **80,000
  single-fault injections, zero placement failures**. Always-DMR (B) prevented
  **100%** of accumulator faults from reaching the output (wrong = 0/5000);
  adaptive C1/C2 raised their flag **before** the corrupted output in 100% of
  F-01 cases but a lone small fault does not escalate to blocking, so wrong
  results still committed in ~53% of them — detection and prevention are
  different properties, and the data shows exactly where each variant sits.
- **Timing:** at the original 100 MHz target all variants fail (WNS −2.81 to
  −2.99 ns, Fmax 77–78 MHz). At the **75 MHz signoff constraint (13.333 ns)
  all four variants meet timing: WNS = +0.166 / +0.067 / +0.017 / +0.066 ns,
  TNS = 0** (MT-08 met).
- **Area (MT-05, signoff build):** protection costs B +100.0% LUT, C1 +113.4%
  LUT, C2 +82.8% LUT versus A; flip-flops +34.0% / +36.5% / +37.9%; BRAM = DSP
  = 0 on all variants.
- **Throughput (MT-07):** A 90.9, B 90.9, C1 90.8, C2 87.4 committed results
  per 1000 cycles — adaptation costs C2 3.5% throughput, C1 ~0%.
- **Power (MT-09):** SAIF-annotated post-route power (7–12% annotation
  coverage, disclosed per row): total 93 / 99 / 98 / 96 mW for A / B / C1 /
  C2 — protection overhead **+6.5% (B), +5.4% (C1), +3.2% (C2)**; a
  default-activity comparison run is reported alongside (section 8).

What is *ours* here is the RTL design, the campaign and the measurements; what
is *existing* is the underlying techniques (DMR, checkpoint/replay, watchdog)
and the related systems in section 9. No novelty claim is made beyond these
measured results.

---

## 2. What was built (architecture, beginner explanation)

**The problem in one paragraph.** A charged particle or voltage glitch can flip
one bit in an FPGA. Nothing crashes — the accelerator keeps producing confident
but wrong outputs (silent data corruption). Classical answers are redundancy
(two or three copies of the logic), checkpoint/rollback (save state, replay on
error), and watchdogs (notice the machine hung). All of them cost area/power
*all the time* to defend against events that are *rare*. This project asks:
can the accelerator pay that cost only when needed?

**Modules (14 RTL files, `rtl/`):** `mac_unit` (INT8 multiply-accumulate with a
parity tap), `input_buffer` / `output_buffer` (small FIFOs),
`reliability_monitor` (classifies faults: datapath / control / liveness),
`error_counter` (thresholds TH_ERR=2, TH_SEV=4, saturates at 0xFF — never
wraps), `fault_detector`, `adaptive_controller` (the mode state machine),
`recovery_controller` (checkpoint → replay → verify), `accelerator_core`
(7-state FSM: IDLE, RUN, SHADOW, CHECK, WAIT_OUT, HOLD, REPLAY; state 7 is
illegal and covered by an assertion), `top_module` (parameterized), and four
thin wrappers `top_variant_a/b/c1/c2`.

**How the variants differ** (parameters only — same code):

- A: `MONITOR_EN=0` — no monitor, no protection.
- B: `FORCE_PROTECTED`, DMR always on — two MAC lanes, per-cycle compare.
- C1: adaptive — NORMAL ⇄ MONITORED ⇄ PROTECTED (DMR) ⇄ RECOVERY, driven by
  the error counter; escalation/de-escalation thresholds are T-3/T-6.
- C2: same policy but PROTECTED means *temporal recompute* (run the vector
  again, compare) instead of a second lane — that is why C2's protected-mode
  latency jumps (54.6 vs 31.0 cycles) while C1's does not.

**Beginner note on "adaptive".** Think of it as a car with a switch between
"economy" and "safety" driving modes. A = always economy, B = always safety,
C1/C2 = watch the dashboard (error counter) and switch only when the weather
gets bad. MT-02 in section 5 measures how much time each car actually spent in
safety mode: 0%, 100%, 5.18%, 8.92%.

---

## 3. Process: what was executed, phase by phase

| Phase | Output |
|---|---|
| 1 Novelty/related work | `docs/novelty_analysis.md` (arXiv search, honesty note) |
| 2 Project charter | `docs/project_charter.md` v2.0; board = Arty A7; git absent → zip snapshots |
| 3 Requirements | `docs/requirements_spec.md`: F-01..F-04, MT-01..MT-09, N-01..N-08, V-01..V-08 |
| 4 Architecture | `docs/architecture.md` (frozen: 7-state FSM, checkpoints, thresholds) |
| 5 RTL + unit tests | 14 RTL files; 7 testbenches all PASS; `tb_top_module` golden regression |
| 6 Fault injection | `tb/fault_injector.sv`, `tb/tb_fi_campaign.sv`, `sim/run_fi.ps1` → 80,000 injections |
| 7 Planning docs | `docs/verification_plan.md`, `docs/experiment_plan.md` |
| 8 Synthesis/implementation | `sim/run_synth.ps1`, two constraint sets → section 7 |
| 9 Power | `sim/run_sim.ps1 -SaifPath`, `sim/power.tcl`, `sim/run_power.ps1` → section 8 |
| Report | this file |

Backups (no git on this machine): `backups/phase5_gate_*.zip`,
`backups/phase6_gate_*.zip`.

---

## 4. Verification results (Phases 5–6, requirements V-01..V-08)

### 4.1 Testbench inventory and outcomes

| Testbench | Covers | Result |
|---|---|---|
| tb_mac_unit | V-01 directed+random vs reference | PASS |
| tb_reliability_monitor | V-02 per-class `err_class` | PASS |
| tb_adaptive_controller | V-03 transitions T-1..T-9 + illegal guards | PASS |
| tb_fault_detector | V-04 detection latency ≤ 2 cycles | PASS |
| tb_error_counter | thresholds, clear, saturation (N-07) | PASS |
| tb_accelerator_core | DMR and temporal replay correctness | PASS (dmr 52 vec, tmp 30 vec) |
| tb_top_module | V-06/V-08 golden regression, N-07 SVA | PASS (see 4.2) |

V-05 audit (grep of `rtl/` for `force`/`inject`/`initial`/`$display`/`#delay`):
only *comments* mention them — no injector or simulation-only code in `rtl/`.

### 4.2 Top-level golden regression (`tb_top_module`)

Fixed stimulus (seed 0xDEADBEEF), 1200 vectors per variant, expected-value FIFO
scoreboard, all four variants driven in lockstep. Final verdict: **PASS,
errors = 0**, where `errors` includes the four SVA guard counters.

Measured metrics:

| Metric | A | B | C1 | C2 |
|---|---|---|---|---|
| MT-02 protection-active time | 0.00% | 100.00% | 5.18% | 8.92% |
| MT-06 latency, normal mode (n) | 30.9 (1248) | — | 31.0 (1184) | 31.0 (1137) |
| MT-06 latency, protected mode (n) | — | 30.9 (1248) | 31.0 (63) | 54.6 (63) |
| MT-07 committed / 1000 cycles | 90.9 | 90.9 | 90.8 | 87.4 |
| Checked results (13735 cycles each) | 1248 | 1248 | 1247 | 1200 |
| **MT-04 false positives** | **0** | **0** | **0** | **0** |

Detection latency (V-04): parity-fault detection observed at **2 cycles** in
the directed test (limit ≤ 2). The fault-injection campaign measures the same
property from a different observation point (deposit → flag): average **1.0
cycle**.

Directed events visible in the run log: gross corruption → RECOVERY (T-2b),
escalation MONITORED→PROTECTED (T-3), de-escalation (T-6), recovery completion
→ MONITORED (T-8), B holding PROTECTED at threshold (err_count=2).

### 4.3 N-07 SVA assertions (added in `tb_top_module.sv`)

1. `a_fsm_legal` — core FSM never in reserved state 7.
2. `a_no_push_when_blocked` — no result pushed into the output buffer while
   `commit_block` is asserted (see amendment, section 11.1).
3. `a_mode_defined` — `mode ∈ {0,1,2,3}` after reset (also catches X).
4. `a_errcnt_no_wrap` — from 0xFF the counter may only stay 0xFF or jump to 0
   (explicit clear); anything else is a wrap.

All four are active in every run and fold into the PASS/FAIL verdict — a
single failure would flip the result to FAIL.

---

## 5. Fault-injection campaign (Phase 6, requirement V-07)

### 5.1 Method (beginner note)

The testbench corrupts the running design *one bit at a time*, at a random
moment while it is working, then watches: does a flag go up *before* a wrong
answer is delivered? Each injection is isolated (reset between injections) so
results are independent. The randomness comes from a Galois LFSR whose seed is
logged in every row (`seed × 0x9E3779B9 | 1`), so any single run can be
reproduced.

- Matrix: 4 configs × {F-01..F-04} × seeds 1..5 × 1000 = **80 runs, 80,000
  injections, `noplace = 0`**.
- Classes: F-01 accumulator XOR (datapath), F-02 output-buffer register
  corruption, F-03 stored-operand corruption (input buffer for A; checkpoint
  for B/C1/C2), F-04 FSM state forced to a random code.
- Classification per injection: `wrong` (a wrong result committed), `detected`
  (flag raised), `detected_wrong` (flag raised *and* a wrong result still
  committed), `hang` (no further progress in 350 cycles), `masked` (fault had
  no observable effect).
- MT-01 = 100 × flagged-before-wrong / 5000 per cell; MT-03 = flag → first
  correct committed output after recovery.

Artifacts: `reports/fi_results.csv` / `.md` (aggregate), `reports/fi_raw.csv`
(80,000 data rows; each run also appends its own header line — cosmetic only),
`build/fi_log.csv` (per-run seed log).

### 5.2 Results (5000 injections per cell)

| cfg | cls | MT-01 % | detected | wrong | det+wrong | hang | masked | avg det lat | avg rec lat |
|---|---|---|---|---|---|---|---|---|---|
| a | F-01 | 0.0 | 0 | 5000 | 0 | 0 | 0 | – | – |
| a | F-02 | 0.0 | 0 | 5000 | 0 | 0 | 0 | – | – |
| a | F-03 | 0.0 | 0 | 4959 | 0 | 0 | 41 | – | – |
| a | F-04 | 0.0 | 0 | 2794 | 0 | 1866 | 340 | – | – |
| b | F-01 | **100.0** | 5000 | **0** | 0 | 0 | 0 | 1.0 | 19.6 |
| b | F-02 | 0.0 | 2367 | 5000 | 2367 | 0 | 0 | 1.0 | – |
| b | F-03 | 0.0 | 0 | 0 | 0 | 0 | 5000 | – | – |
| b | F-04 | 32.2 | 1612 | 4214 | 1396 | 0 | 570 | 106.3 | 14.0 |
| c1 | F-01 | **100.0** | 5000 | 2672 | 2672 | 0 | 0 | 1.0 | 19.1 |
| c1 | F-02 | 0.0 | 2367 | 5000 | 2367 | 0 | 0 | 1.0 | – |
| c1 | F-03 | 0.0 | 0 | 0 | 0 | 0 | 5000 | – | – |
| c1 | F-04 | 24.9 | 1247 | 4214 | 1031 | 0 | 570 | 134.4 | 14.0 |
| c2 | F-01 | **100.0** | 5000 | 2697 | 2697 | 0 | 0 | 1.0 | 28.0 |
| c2 | F-02 | 0.0 | 2367 | 5000 | 2367 | 0 | 0 | 1.0 | – |
| c2 | F-03 | 0.0 | 0 | 0 | 0 | 0 | 5000 | – | – |
| c2 | F-04 | 33.9 | 1693 | 4198 | 1473 | 0 | 582 | 98.3 | 23.0 |

### 5.3 Interpretation (what the table is really saying)

- **A is the honest baseline for "unprotected":** it flags nothing. F-01/F-02
  are 100% silent corruption; F-04 control faults either slip through wrong
  (2794) or hang the pipeline permanently (1866/5000) because A has no
  watchdog — the 1866 hangs are exactly the cost of *not* monitoring control
  state.
- **F-02 by construction:** the output-buffer bit is corrupted *after* the
  result was committed, so no flag can ever precede the wrong delivery —
  MT-01 = 0 for every config. The range check still catches 2367/5000 at
  delivery time (flagged, but late for MT-01's definition).
- **F-03 checkpoint faults are latent:** B/C1/C2 only read the checkpoint
  during a recovery, and a single fault never triggers one → all 5000 masked.
  For A the same fault hits live input-buffer state → 4959 wrong.
- **Detection ≠ prevention (the key adaptive result):** C1/C2 raise the F-01
  flag *before* the wrong output in 100% of injections, but one small-bit fault
  only escalates MONITORED→PROTECTED, which does not block commits — 2672/2697
  wrong results still landed. Only B (always-DMR, wrong = 0) *prevents* all of
  them, at 100% protection-active time. C1/C2 sit between: full detection,
  partial prevention, 5–9% protection time.
- **F-04 watchdog asymmetry:** with a watchdog, hangs are converted into
  detected+recovered events (B/C1/C2 hang = 0), average detection ~100 cycles
  (watchdog window), recovery 14–23 cycles.

---

## 6. Verification/requirement status at a glance

| Req | Status | Evidence |
|---|---|---|
| V-01..V-04 | PASS | unit TB logs (section 4.1) |
| V-05 | PASS | grep audit of `rtl/` |
| V-06 | PASS | tb_top: 0 mismatches, 0 SVA failures → MT-04 = 0 |
| V-07 | PASS | 80 runs / 80,000 injections, `fi_results.csv` |
| V-08 | PASS | identical golden vectors, all 4 configs |
| MT-01/MT-03 | MEASURED | section 5.2 |
| MT-02/04/06/07 | MEASURED | section 4.2 |
| MT-08 | PASS @ 75 MHz | section 7 (WNS ≥ 0, TNS = 0) |
| MT-09 | MEASURED | section 8 |
| N-01..N-06, N-08 | PASS | single-clock XDC, reset policy, no latches (synth clean), comments, sim-only confined to `tb/`, fixed seeds |
| N-07 | PASS (amended) | 4 SVA guards + counter saturation test; amendment 11.1 |

---

## 7. Synthesis and implementation (Phase 8)

Flow: non-project batch Vivado (`sim/synth_impl.tcl` driven by
`sim/run_synth.ps1`), read → synth → opt → place → route → reports →
checkpoint, staged into a space-free temp workspace because Vivado's file
commands truncate paths at spaces (deviation 11.3).

**Beginner note on the two runs.** The first constraint set is the original
100 MHz target — it fails, and reporting that failure honestly (with the
reason) is more useful than hiding it. The second is 75 MHz, chosen because it
clearly closes timing with margin; *that* is the signoff number for MT-08.

### 7.1 Characterization at 100 MHz (10 ns, post-route)

| variant | LUT | FF | BRAM | DSP | WNS (ns) | TNS (ns) | critical path (ns) | Fmax (MHz) | critical path from → to |
|---|---|---|---|---|---|---|---|---|---|
| a | 294 | 480 | 0 | 0 | −2.806 | −92.007 | 12.806 | 78.1 | `u_obuf/rptr_reg[1] → out_result[2]` |
| b | 609 | 643 | 0 | 0 | −2.970 | −144.043 | 12.970 | 77.1 | `u_obuf/rptr_reg[1] → out_result[17]` |
| c1 | 648 | 655 | 0 | 0 | −2.952 | −143.265 | 12.952 | 77.2 | `u_obuf/rptr_reg[0] → out_result[22]` |
| c2 | 534 | 662 | 0 | 0 | −2.992 | −117.279 | 12.992 | 77.0 | `u_obuf/rptr_reg[1] → out_result[1]` |

*(Fmax = 1/(period − WNS) per MT-08's definition; here period − WNS is the
measured path delay.)*

Where the time actually goes — two distinct problems, measured separately
(`reports/timing_path_*.rpt`, `reports/timing_path2reg_*.rpt`):

1. **Output-pad paths** (the WNS above): register → `out_result` pad with a
   2 ns external output delay; the OBUF alone costs 2.64 ns and the clock
   insertion delay to the launching FF is 4.66 ns. Only 2 logic levels — this
   is an interface-path limit, not deep logic.
2. **Internal register-to-register paths** (worst per variant): input-buffer
   read → MAC accumulate → parity XOR in one cycle, DSP = 0 (the multiplier is
   LUT-mapped). Slacks at 10 ns: A −0.587, B −2.578, C1 −2.561, C2 −2.781 ns.
   The parity/compare logic of the protected variants roughly quadruples the
   internal violation.

### 7.2 Signoff at 75 MHz (13.333 ns, post-route) — MT-08

| variant | LUT | FF | BRAM | DSP | WNS (ns) | TNS (ns) | path (ns) | Fmax (MHz) | critical path from → to |
|---|---|---|---|---|---|---|---|---|---|
| a | 291 | 480 | 0 | 0 | **+0.166** | 0 | 13.167 | 75.9 | `u_obuf/mem_reg[2][29] → out_result[29]` |
| b | 582 | 643 | 0 | 0 | **+0.067** | 0 | 13.266 | 75.4 | `u_obuf/mem_reg[2][1] → out_result[1]` |
| c1 | 621 | 655 | 0 | 0 | **+0.017** | 0 | 13.316 | 75.1 | `u_ibuf/rptr_reg[1] → u_lane_a/acc_parity_reg` |
| c2 | 532 | 662 | 0 | 0 | **+0.066** | 0 | 13.266 | 75.4 | `u_ibuf/rptr_reg[1] → u_lane_a/acc_parity_reg` |

**MT-08 met: every variant WNS ≥ 0, TNS = 0 at 13.333 ns.** Note the critical
path migrates: A/B are still interface-bound, while C1/C2 are bound by the
internal parity path — the protection logic is the limiter there, exactly as
the internal-path analysis predicted.

### 7.3 Area overhead MT-05 (signoff build, vs A)

| metric | A | B | C1 | C2 |
|---|---|---|---|---|
| LUT | 291 | 582 (+100.0%) | 621 (+113.4%) | 532 (+82.8%) |
| FF | 480 | 643 (+34.0%) | 655 (+36.5%) | 662 (+37.9%) |
| BRAM / DSP | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |

(LUT counts differ slightly between the 100 MHz and 75 MHz builds — timing-
driven optimization rewrites logic when the constraint changes; both sets are
reported as measured.)

---

## 8. Power (Phase 9, MT-09)

**Beginner note.** Power has two parts: *dynamic* (energy spent switching
transistors — depends on what the circuit is actually doing) and *static*
(leakage — depends only on the device). On this part the static ~60 mW is the
same for every variant (same chip, near-idle utilization), so the interesting
number is how much *dynamic* power each protection scheme adds.

**Method.** SAIF activity captured from the golden regression trace
(`run_sim.ps1 -Tb tb_top_module -SaifPath ...`, full hierarchy via
`log_saif [get_objects -r *]` with `-debug all`: 1.5 MB, 50 scopes, whole
137,375 ns run, all four variants driven with identical vectors), then per
variant: open the routed signoff checkpoint →
`read_saif -strip_path tb_top_module/h_<v>.g<v>.u_v` → `report_power`
(`sim/power.tcl`, `sim/run_power.ps1`). Vivado's own `Design nets matched = N
of M` is recorded per run: post-synthesis net-name absorption limits
annotation coverage, and **every row below discloses its annotated
percentage** (unannotated nets use Vivado's probabilistic defaults).

### 8.1 SAIF-annotated results (MT-09 primary, `_p75` signoff checkpoints)

| variant | SAIF annotation | dynamic (mW) | static (mW) | **total (mW)** | total vs A |
|---|---|---|---|---|---|
| a | 12% (130/1050 nets) | 33 | 60 | **93** | — |
| b | 7% (132/1826) | 38 | 60 | **99** | +6.5% |
| c1 | 7% (141/1884) | 38 | 60 | **98** | +5.4% |
| c2 | 11% (173/1621) | 35 | 60 | **96** | +3.2% |

### 8.2 Default-activity comparison (activity-source sensitivity)

| variant | dynamic (mW) | static (mW) | total (mW) | total vs A |
|---|---|---|---|---|
| a | 34 | 60 | 95 | — |
| b | 35 | 60 | 95 | 0.0% |
| c1 | 35 | 60 | 96 | +1.1% |
| c2 | 40 | 60 | 101 | +6.3% |

### 8.3 Interpretation

- Under the primary SAIF flow, always-DMR (B) costs **+15% dynamic / +6.5%
  total**, adaptive DMR (C1) +15% dynamic / +5.4% total, adaptive recompute
  (C2) only **+6% dynamic / +3.2% total** — C2 is the cheapest protection in
  watts under measured activity, matching its smaller protected-time window.
- The default-activity run **disagrees on ranking** (it places C2 highest) —
  default toggle rates cannot see that B's second lane toggles every cycle
  while C2's recompute is bursty. With 7–12% annotation both are
  approximations, so the defensible claim is deliberately narrow:
  *protection adds single-digit-percent total power on this device; the
  per-variant ranking is activity-source-sensitive and reported for both
  sources rather than asserted for one.* (`reports/power_results_p75.csv`,
  `reports/power_results_p75_default.csv`.)

---

## 9. Related work (verified sources) and positioning

Found in the Phase-1 arXiv search and re-verified by web search on 2026-09-28
(honesty note from `novelty_analysis.md` still applies: IEEE Xplore / ACM DL
were not exhaustively searched):

1. **WARD** — *Runtime Workload-Adaptive Vision TRansformer Framework for
   Dependable Edge AI*, arXiv:2609.17556 (20 Jul 2026). Four runtime operating
   modes on a lightweight FPGA accelerator, <5% area overhead, mode transitions
   in a few cycles, 1.79% network-level failure rate under high BER. Closest
   work: also runtime-adaptive reliability on FPGA — but at *system/framework*
   level (ViT subnetworks, continual learning), not an RTL protection
   controller for a MAC datapath.
2. **ProWAFT** — *A ROMA-LPD Instance for Workload-Aware and Dynamic Fault
   Tolerance in FPGA-Based CNN Accelerators*, arXiv:2607.01602 (2 Jul 2026).
   Selective TMR via partial reconfiguration on ZCU104; composite
   latency/energy/reliability objective; throughput 0.61 → 0.89 vs static TMR.
   Adapts *where* redundancy is placed through reconfiguration — our C1/C2
   adapt *whether* redundancy is active at all, in plain RTL, no PR.
3. **RePAIR** — *Fast SEU Detection and Recovery in FPGA-Based AI
   Accelerators*, ACM TRETS, doi 10.1145/3806052. RISC-V + systolic accelerator,
   checksum testing (3 cycles/multiply), partial-reconfiguration recovery up to
   900× faster than full reconfiguration, ≤30% inference overhead.
4. **EIR** — *Emulated Integrity Replica*, arXiv:2607.12298. Hierarchical
   digital twins on the PS side of a Zynq; cites DMR baseline cost of 2.0–2.25×
   LUT/FF and 2.98 → 5.79 W — consistent in spirit with our measured DMR
   LUT doubling (+100.0%).
5. **FPGA-based emulation + fault injection for CNN accelerators**,
   arXiv:2501.12818, and **AFarePart** (accuracy-aware fault-resilient
   partitioning), arXiv:2512.07449 — background for FI methodology.

**Positioning (no novelty overclaim).** This project does not claim a new
fault-tolerance technique. Its contribution is a complete, reproducible,
from-scratch RTL study: one parameterized accelerator, four protection
policies, a same-workload comparison with quantified detection/prevention
trade-offs from 80,000 injections, and honest timing/power cost accounting on a
real FPGA part. The measured "detection ≠ prevention" gap in C1/C2 (section
5.3) is the concrete finding a follow-on design would need to close (e.g.,
blocking commits in MONITORED mode or escalating single severe faults to
RECOVERY).

---

## 10. Reproducibility

From the project root (`vlsi-adaptive-accelerator/`), PowerShell:

```powershell
# unit + top regression (add -SaifPath for the power trace)
powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1 -Tb tb_top_module

# 80-run / 80,000-injection campaign -> reports/fi_results.csv
powershell -ExecutionPolicy Bypass -File sim\run_fi.ps1

# synthesis + implementation (100 MHz characterization, 75 MHz signoff)
powershell -ExecutionPolicy Bypass -File sim\run_synth.ps1 -PeriodTag 100
powershell -ExecutionPolicy Bypass -File sim\run_synth.ps1 -PeriodTag 75

# internal critical paths from routed checkpoints
#   (stage build/*.dcp to a space-free dir, then: vivado -mode batch -source sim\report_paths.tcl)

# MT-09 power (SAIF trace first, then per-variant report_power;
# add -DefaultActivity for the activity-source comparison run)
powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1 -Tb tb_top_module `
    -SaifPath "$env:LOCALAPPDATA\Temp\opencode\saif\tb_top.saif"
powershell -ExecutionPolicy Bypass -File sim\run_power.ps1
powershell -ExecutionPolicy Bypass -File sim\run_power.ps1 -DefaultActivity
```

Key artifacts: `reports/fi_results.{csv,md}`, `reports/fi_raw.csv`,
`reports/synth_results{,_p75}.{csv,md}`, `reports/timing_*.rpt`,
`reports/timing_path_*.rpt`, `reports/timing_path2reg_*.rpt`,
`reports/util_*.rpt`, `reports/drc_*.rpt`, `reports/power_*`,
checkpoints `build/top_variant_*[_p75].dcp`, per-run logs `build/*.out`.

---

## 11. Deviations, incidents, and fixes (the "what changed and why")

1. **N-07 amendment.** The literal requirement "no `out_valid` during
   `commit_block`" would forbid draining results that were already committed
   *before* a fault. The design gates the *push* into the output buffer
   (`wr_valid = core_res_valid && !commit_block`); draining pre-fault results
   is correct behavior — every drained value passes the golden scoreboard. The
   SVA therefore asserts the push-side invariant. Rationale documented in
   `verification_plan.md` §4.
2. **RTL fix (found by regression):** `accelerator_core`'s default (illegal
   state 7) case went to `ST_IDLE`, which would orphan an in-flight recovery
   handshake/replay. Changed to `ST_HOLD`; `tb_accelerator_core` and
   `tb_top_module` re-run and passed with identical metrics afterwards.
3. **Vivado path truncation:** file commands cut paths at the first space
   (`File 'C:/Users/user/Documents/Default' does not exist`). Fix: stage the
   workspace to `%LOCALAPPDATA%\Temp\opencode\vlsi_synth` before every Vivado
   run (`run_synth.ps1`).
4. **xsim plusargs:** the loader splits valued plusargs at `=`. Fix: campaign
   parameters reach the TB through `build/fi_args.txt`.
5. **xsim `-tclbatch` path handling:** xsim sources the batch file with an
   unquoted `source` — backslashes are eaten and the first space splits the
   command. Fix: the SAIF batch lives at a space-free, forward-slash path.
6. **SAIF pipeline discovery:** `open_saif` alone writes only a header; a
   `log_saif` call is required (see item 10 for the scope-pattern correction),
   and the snapshot must be elaborated with `-debug all` (`Simulator 45-10`
   otherwise). Fixed in `run_sim.ps1`.
7. **Transient Vivado crash:** one tag-100 run of variant C2 died with
   `EXCEPTION_ACCESS_VIOLATION` during `report_drc` (after its timing reports
   were written), which dropped C2 from the aggregated CSV. Fix: full tag-100
   re-run; the CSV is only ever written from complete in-invocation results.
8. **Power-shell scripting:** `.ps1` files must be ASCII-only (em-dashes break
   parsing under the ANSI codepage); single-match `Select-Object` results
   wrapped in `@()` before `.Count`.
9. **100 MHz signoff failure** is reported, not hidden: structural limits are
   identified per path (section 7.1); the 75 MHz run is the signoff. A
   DSP-inferred pipelined MAC would be the obvious fix but the architecture was
   frozen before synthesis — deliberately not changed post-freeze.
10. **SAIF hierarchy discovery (MT-09):** the first capture used
    `log_saif /*`, which per xsim only logs the *matched scope's own signals* —
    the resulting 165 KB file contained `tb_top_module` top-level nets only and
    annotated 3/1050 nets. UG900's recursive form `log_saif [get_objects -r *]`
    was adopted; the re-captured trace is 1.5 MB with all 50 scopes, and the
    golden run still PASSes with byte-identical metrics.
11. **`read_saif -strip_path` form:** xsim writes the generate/instance
    boundary as the escaped name `gA\.u_v`, but Vivado's SAIF reader normalizes
    it to a plain dot; the working strip is
    `tb_top_module/h_<v>.g<v>.u_v` with slash separators. The
    `[Power 33-395] Could not find -strip_path` warning remains cosmetic —
    matched-net counts confirm the strip is applied (verified by probing
    candidate forms against the live checkpoint).
12. **Annotation coverage is partial, and disclosed:** post-synthesis net
    absorption (ports merged across hierarchy, combinational nets renamed
    `*_i_1_n_0`/`*_carry_*`) caps SAIF annotation at 7–12% of nets
    (variant-dependent, from Vivado's own `Design nets matched = N of M`).
    Every power row reports its annotated percentage, and a
    `-DefaultActivity` comparison run is stored alongside
    (`power_results_p75_default.csv`) so the activity-source sensitivity is
    visible rather than hidden.
13. **`report_power` labels:** Vivado 2025.2 emits `Total On-Chip Power (W)`,
    not a bare `Total (W)` row — the first parse attempt matched nothing and
    the parser was corrected (the report files themselves were valid).

## 12. Limitations and future work

- RTL-level fault model: deposits target modeled signals, not bitstream
  configuration bits; conclusions do not transfer 1:1 to device-level SEUs.
- Single clock domain, no CDC (N-01 by design).
- C1/C2 commit wrong results after a *detected* small fault (section 5.3) —
  the clearest next improvement: block commits in MONITORED mode or escalate
  severe-class faults directly to RECOVERY, then re-run the same campaign.
- Power numbers depend on annotation coverage and activity source: both are
  measured and disclosed (SAIF 7–12% annotated as primary, default-activity
  run as comparison), but a keep-annotated netlist or post-synth
  gate-level SAIF would be needed for tighter numbers.
- Literature: extend the search to IEEE Xplore/ACM DL before any publication.
