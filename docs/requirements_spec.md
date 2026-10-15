# PHASE 2 — Requirements Specification (v1.0)

**Status:** APPROVED v1.0 (2026-09-25) — Section 9 open items all closed.
**Scope:** simulation + synthesis + implementation on PC; **board = Digilent Arty A7** (bitstream phase deferred).
**Tooling:** Vivado 2025.2 (`D:\Xilinx\2025.2\Vivado\bin\vivado.bat`), xsim, VS Code.

Every requirement has a unique ID. RTL and testbenches trace to these IDs.

---

## 1. System overview

A parameterized INT8 dot-product engine ("accelerator core") plus a reliability
subsystem. One design, four build configurations (A, B, C1, C2 — see charter §4),
one shared fault-injection testbench.

```
input_buffer → accelerator_core (MAC array + accumulator) → output_buffer
                        │
                  observed datapath values (taps)
                        ▼
        reliability_monitor → error_counter → adaptive_controller ──► mode[1:0]
                        ▲                            │                    │
                  fault_detector                 recovery_controller ◄───┘
                        ▲                                              │
                 fault_injector (SIMULATION ONLY, tb/ folder)          ▼
                                                            protection enable,
                                                            checkpoint/replay ctrl
```

## 2. Configuration parameters (functional requirements)

| ID | Requirement | Default | Notes |
|---|---|---|---|
| P-01 | Data width `DATA_W` configurable | 8 (INT8) | parameter; TB also exercises DATA_W=4 |
| P-02 | Accumulator width `ACC_W` configurable | 32 | must not overflow for VEC_LEN=64 max |
| P-03 | Vector length `VEC_LEN` (MACs per dot product) | 8 | parameter, 4–64 range |
| P-04 | Number of parallel MAC lanes `NUM_PE` | 2 | keeps DSP count small but nonzero; DSP% meaningful |
| P-05 | All parameters overridable per build | — | same RTL, different top-level params |

## 3. Operating modes (authoritative)

### 3.1 Mode encoding

| Code | Name | Layer 1 (cheap sensor) | Layer 2 (heavy protection) | Throughput |
|---|---|---|---|---|
| `2'd0` | **NORMAL** | **Coarse:** range check on each *committed* dot-product result only | OFF | 100% |
| `2'd1` | **MONITORED** | **Fine:** per-cycle parity on accumulator + range check + illegal-FSM-state check + watchdog | OFF | 100% |
| `2'd2` | **PROTECTED** | Fine (always) | **C1/B:** DMR compare every cycle · **C2:** temporal recompute-and-compare | C1/B: 100% · C2: 50% |
| `2'd3` | **RECOVERY** | Fine | checkpoint replay + verification | degraded, bounded |

**Design decision (from Phase-1 review, Option 1): NORMAL mode is never fully blind.**
A coarse per-result range check remains active so escalation is always possible.
Boot state = **MONITORED** (safe default).

### 3.2 Transition table (exact, numeric)

Configurable constants (top-level parameters, sweepable):

| Symbol | Default | Meaning |
|---|---|---|
| `TH_ERR` | **2** | error-count threshold to escalate MONITORED→PROTECTED |
| `H_CLEAN` | **64** | clean committed results required: PROTECTED→MONITORED |
| `N_QUIET` | **1024** | clean committed results required: MONITORED→NORMAL |
| `TH_SEV` | **4** | error count within window ⇒ severe → RECOVERY |
| `REC_MAX` | **3** | max replay attempts before sticky `fault_latched` |
| `WD_CYC` | **256** | watchdog timeout (cycles without committed result while busy) |

| # | From | To | Condition (exact) | Priority |
|---|---|---|---|---|
| T-1 | (reset) | MONITORED | `rst_n` deasserted | — |
| T-2 | NORMAL | MONITORED | coarse check error OR any monitor error pulse | — |
| T-3 | MONITORED | PROTECTED | `err_count >= TH_ERR` (errors need not be consecutive) | — |
| T-4 | MONITORED | RECOVERY | `err_count >= TH_SEV` OR watchdog timeout OR illegal FSM state | higher than T-3 |
| T-5 | PROTECTED | RECOVERY | DMR mismatch (C1/B) OR recompute mismatch (C2) OR `err_count >= TH_SEV` | — |
| T-6 | PROTECTED | MONITORED | `clean_count >= H_CLEAN` AND `err_count == 0` (de-escalation; counter reset on entry to PROTECTED) | — |
| T-7 | MONITORED | NORMAL | `clean_count >= N_QUIET` AND `err_count == 0` | — |
| T-8 | RECOVERY | MONITORED | replay completed AND result verified AND attempt `< REC_MAX` | — |
| T-9 | RECOVERY | (hold) | attempts `>= REC_MAX` ⇒ set `fault_latched=1`, stop committing outputs, require external `clear_latched` | highest |

**Hysteresis rule:** de-escalation counters (`clean_count`) reset whenever an error
occurs; escalation uses raw `err_count`. This prevents mode oscillation ("flapping").

### 3.3 Mode semantics (what must happen in each mode)

- M-01: Pipeline output commit is suppressed in RECOVERY until replay verified.
- M-02: `mode` output reflects state in the *same* cycle as transition (registered, 1-cycle registered output acceptable; documented).
- M-03: C1 gates layer-2 clock/enable only — identical logic to B otherwise.
- M-04: C2 issues one shadow recompute per committed dot product while in PROTECTED; compares before commit.
- M-05: All four configs share identical monitor/counter/FSM logic (only layer-2 differs).

## 4. Fault model (simulation-only)

| ID | Fault class | Injection mechanism | Target |
|---|---|---|---|
| F-01 | MAC result flip | XOR 1 random bit into product/accumulator value | datapath tap inside core |
| F-02 | Register corruption | XOR 1 bit into input/weight/output register | named register target |
| F-03 | Weight corruption | XOR 1 bit into a stored weight | weight register file |
| F-04 | Control disturbance | force FSM state to a random legal-other state (or illegal code for F-04b) | control FSM state reg |

**Rules:**
- F-01..F-04 are implemented **only in `tb/fault_injector.sv`** (or via `force`/`release`); no injector logic in `rtl/` (requirement V-05).
- Injection schedule: LFSR PRNG, **seed fixed and logged** (default seed list: 1..5 seeds × ≥1000 injections per class per configuration ⇒ ≥20,000 injections/config total).
- Injection time: pseudo-random cycle within an active window (not during reset).
- Fault duration: permanent-for-that-run for F-02/F-03; single-cycle pulse for F-01/F-04 (documented per campaign).
- Detection observation points: monitor error flag **and** output-commit interface **and** watchdog (never output-only — per Phase-1 Belle II finding).

## 5. Metric definitions (formulas — locked)

| ID | Metric | Formula | Source |
|---|---|---|---|
| MT-01 | Detection coverage | `100 × (injections raising monitor/commit-flag BEFORE wrong output committed) / (total injections)` per class and overall | FI campaign log |
| MT-02 | Protection-active time | `100 × (cycles in PROTECTED or RECOVERY) / (total measured cycles)` | mode trace from RTL sim |
| MT-03 | Recovery latency | cycles from detection flag → first correct committed output post-recovery (averaged over successful recoveries) | FI campaign log |
| MT-04 | False-positive rate | `100 × (error flags in fault-free run) / (total results)` — must be **0** in golden run | regression TB |
| MT-05 | Overhead % | `100 × (value_variant − value_A) / value_A` for LUT, FF, DSP, power | Vivado reports |
| MT-06 | Latency | cycles from first input `valid` to output `valid` for one dot product | RTL sim |
| MT-07 | Throughput | committed dot products per 1000 cycles (steady state) | RTL sim |
| MT-08 | Fmax / WNS | Vivado post-implementation `WNS ≥ 0`; Fmax = 1/(period − WNS) at target period | implementation report |
| MT-09 | Power | Vivado post-impl power with **SAIF** from gate-level sim of fixed trace; report dynamic + total, as absolute (mW) and as MT-05 % | power report |

Target clock (initial, revisited at Phase 8): **100 MHz** on part TBD.

## 6. Interface requirements (port contracts — draft, frozen at Phase 3/4)

All modules: single clock `clk`, async-assert/sync-release active-low reset `rst_n`.

| Module | Inputs | Outputs |
|---|---|---|
| `mac_unit` | `a[DATA_W]`, `b[DATA_W]`, `acc_clear`, `in_valid` | `result[ACC_W]`, `out_valid`, `range_err` |
| `input_buffer` | `wr_data`, `wr_valid`, `rd_ready` | `rd_data`, `rd_valid`, `empty`, `full` |
| `output_buffer` | `wr_valid`, `wr_data`, `rd_ready` | `rd_data`, `rd_valid`, `commit` |
| `reliability_monitor` | taps: `acc`, `result`, `fsm_state`, `busy`, `wd_en` | `err_pulse`, `err_class[1:0]` (00 none,01 datapath,10 control,11 liveness) |
| `error_counter` | `err_pulse`, `clr`, `threshold[7:0]` | `count[7:0]`, `thresh_hit` |
| `fault_detector` | monitor taps, `dmr_match`/`temporal_match` | `detected`, `severe`, `class_code` |
| `adaptive_controller` | `thresh_hit`, `severe`, `clean_ok`, `wd_timeout`, `recovery_ok`, `latched_clr` | `mode[1:0]`, `prot_en`, `monitor_fine`, `recovery_req`, `fault_latched` |
| `recovery_controller` | `recovery_req`, `checkpoint_valid`, `replay_result`, `verify_ok` | `replay_active`, `attempt[1:0]`, `recovery_ok`, `commit_block` |
| `top_module` | `start`, `in_data`, `in_valid`, `clear_latched` | `result`, `out_valid`, `mode[1:0]`, `err_count`, `fault_latched` |

(`err_class`/`class_code` = fault classification requirement from project spec.)

## 7. Non-functional requirements

| ID | Requirement |
|---|---|
| N-01 | Synchronous, single clock domain; no derived clocks |
| N-02 | Active-low reset, async assert / synchronous de-assert; all state has defined reset value |
| N-03 | No inferred latches: every `always_comb` fully assigned; defaults specified |
| N-04 | Synthesizable SystemVerilog only in `rtl/`; no `#delays`, no `initial`, no `$display` in RTL |
| N-05 | Simulation-only constructs confined to `tb/` (fault injector, checkers, scoreboards) |
| N-06 | Deterministic: fixed seeds; golden vectors checked against behavioral reference model |
| N-07 | Assertions in TB (SVA): FSM never in reserved/illegal state; no `out_valid` during `commit_block`; mode ∈ {0..3}; counters never wrap silently |
| N-08 | Meaningful signal names, comments on every FSM and non-obvious decision |

## 8. Verification requirements (traceability)

| ID | Requirement | Gate |
|---|---|---|
| V-01 | `tb_mac_unit.sv` — directed + random vectors vs reference (self-checking) | Phase 5 |
| V-02 | `tb_reliability_monitor.sv` — each fault class produces correct `err_class` | Phase 5 |
| V-03 | `tb_adaptive_controller.sv` — every transition T-1..T-9 exercised; illegal transitions asserted impossible | Phase 5 |
| V-04 | `tb_fault_detector.sv` — detection latency ≤ 2 cycles for fine checks | Phase 5 |
| V-05 | Audit: no injector code in `rtl/` (grep for `force`, `inject`) | Phase 6 |
| V-06 | `tb_top_module.sv` — golden-vector regression, 0 false positives (MT-04=0) | Phase 6 |
| V-07 | FI campaign: ≥1000 injections × 4 classes × 5 seeds per config; logs → MT-01/MT-03 | Phase 6/7 |
| V-08 | All four configs pass identical golden vectors (functional equivalence when no faults) | Phase 7 |

## 9. Open items — ALL CLOSED (approved by user, 2026-09-25)

1. ~~Vivado version + target part~~ → Vivado 2025.2; board = **Digilent Arty A7**
   (variant 35T = `xc7a35ticsg324-1L` / 100T = `xc7a100tcsg324-1` — confirm before Phase 8;
   either is sufficient for this design).
2. ~~Threshold defaults~~ → approved as specified: `TH_ERR=2, H_CLEAN=64, N_QUIET=1024, TH_SEV=4`.
3. ~~NORMAL = coarse-checking (never fully blind)~~ → **approved**. NORMAL retains one
   range check per committed result; no mode is ever fully blind. (A — the bare baseline
   config — is intentionally blind: it is the reference, not a protected design.)
