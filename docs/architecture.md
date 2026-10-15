# PHASE 3 — System Architecture (v1.0)

**Date:** 2026-09-25 · **Status:** APPROVED (supersedes requirements §6 "draft" interfaces where marked FINAL)

## 1. Design parameters (frozen)

| Parameter | Default | Range | Meaning |
|---|---|---|---|
| `DATA_W` | 8 | 4,8 | INT8 operand width |
| `ACC_W` | 32 | 32 | accumulator width (≥16 for DATA_W=8,VEC=64) |
| `VEC_LEN` | 8 | 4..64 | operands per dot product |
| `TH_ERR` | 2 | 1..8 | escalate MONITORED→PROTECTED |
| `H_CLEAN` | 64 | 16..256 | clean results: PROTECTED→MONITORED |
| `N_QUIET` | 1024 | 64..4096 | clean results: MONITORED→NORMAL |
| `TH_SEV` | 4 | 2..8 | severe → RECOVERY |
| `REC_MAX` | 3 | 1..7 | recovery attempts before `fault_latched` |
| `WD_CYC` | 256 | 32..1024 | watchdog timeout (cycles busy without progress) |

Range bound used by range check: `MAX_ABS = VEC_LEN * (2^(DATA_W-1)-1)^2`
(= 8×16129 = 129032 for defaults) — a committed result outside ±MAX_ABS is corrupt.

## 2. Block architecture (FINAL)

```
                         in_a/in_b (DATA_W each)
                               │ in_valid
                    ┌──────────▼──────────┐
                    │    input_buffer     │  FIFO, depth 16, stores {a,b}
                    └──────────┬──────────┘
                               │ rd_valid
                    ┌──────────▼──────────────────────────────────────────┐
                    │  accelerator_core                                   │
                    │  ┌─────────────┐   ┌─────────────┐  (lane A always) │
                    │  │  mac_unit   │   │ mac_unit B  │  ← HAS_DMR: B/C1 │
                    │  │  (lane A)   │   │ (lane B)    │    gated by      │
                    │  └──────┬──────┘   └──────┬──────┘    prot_en (C1)  │
                    │   acc ──┤   compare at commit (dmr_match)            │
                    │  ┌──────▼──────────────┐                            │
                    │  │ operand checkpoint  │  vec_a[], vec_b[] (FF array)│
                    │  │ + temporal recompute│  ← HAS_TEMPORAL: C2         │
                    │  └─────────────────────┘                            │
                    │  FSM {IDLE,RUN,SHADOW,COMMIT,WAIT_OUT,REPLAY}       │
                    │  taps: acc, state, busy, result                     │
                    └──────┬──────────────────────────────────────────────┘
                           │ committed result
                    ┌──────▼──────────┐
                    │  output_buffer  │  ── out_result/out_valid/commit
                    └─────────────────┘
   ─────────────────────────── reliability subsystem ───────────────────────
   taps: acc, acc_parity, result, core_state, busy
        ┌───────────────────────┐   ┌──────────────┐   ┌───────────────────┐
        │ reliability_monitor   │──▶│ error_counter │──▶│adaptive_controller│
        │ coarse: range         │   │ count vs      │   │ FSM: NORMAL /     │
        │ fine: +parity+fsm+wd  │   │ TH_ERR/TH_SEV │   │ MONITORED/        │
        │ err_class[1:0]        │   └──────────────┘   │ PROTECTED/RECOVERY│
        └───────────────────────┘                      └─────┬─────────────┘
        ┌───────────────────────┐                            │ prot_en,
        │ fault_detector        │◀── dmr_match/temporal_match│ monitor_fine,
        │ detected/severe/class │───────────────────────────▶│ recovery_req
        └───────────────────────┘   ┌──────────────────┐     │ mode[1:0]
                                    │recovery_controller│◀────┘
                                    │ replay, attempts, │──▶ commit_block
                                    └──────────────────┘
```

## 3. Configuration variants (FINAL) — one RTL, four builds

`top_module` is parameterized; each variant is a thin wrapper with fixed params:

| Wrapper | `MONITOR_EN` | `HAS_DMR` | `HAS_TEMPORAL` | `FORCE_MODE` | Expected character |
|---|---|---|---|---|---|
| `top_variant_a` | 0 | 0 | 0 | `NORMAL` (no monitor) | bare reference |
| `top_variant_b` | 1 | 1 | 0 | `PROTECTED` (forced) | always-protected |
| `top_variant_c1` | 1 | 1 | 0 | adaptive | policy-gated DMR |
| `top_variant_c2` | 1 | 0 | 1 | adaptive | temporal recompute |

- **B is C1 with the controller forced to PROTECTED** → identical logic ⇒ B-vs-C1 isolates *policy* (charter §4).
- `FORCE_MODE != ADAPTIVE` optimizes the controller FSM to constants at synthesis ⇒ A gets minimal area; B keeps monitor + DMR + comparator always active (protection-active = 100% by construction).
- When no faults: **all four are functionally identical** (requirement V-08) — verified against the same golden vectors.

## 4. Datapath / control timing (one dot product, VEC_LEN=8, NUM_PE=1 lane active)

```
cycle:  1    2    3 ... 8    9      10     11     12
       in_0 in_1 in_2   in_7 commit ──────────────────▶ out_valid
       acc: ─▶ ─▶ ─▶     acc_max
DMR (B/C1): lane B mirrors lane A every cycle; compare at commit (cycle 9)
TEMPORAL (C2): cycle 9,10..16 shadow recompute from checkpoint
               cycle 17 compare → commit ⇒ throughput ≈ 50% in PROTECTED
RECOVERY: commit blocked; REPLAY state recomputes from checkpoint (≤VEC_LEN
          + VEC_LEN cycles), verify, attempt++, commit or fault_latched
```

- Detection latency (fine checks): ≤ 2 cycles (requirement V-04).
- Commit suppressed while `commit_block=1` (RECOVERY/unverified).

## 5. Module hierarchy (build order = dependency order)

```
top_variant_{a,b,c1,c2}.sv
└── top_module.sv            (params → selects variant internals)
    ├── input_buffer.sv
    ├── accelerator_core.sv
    │   ├── mac_unit.sv        ×1 (A,C2) ×2 (B,C1)
    │   └── (checkpoint array, temporal shadow — inside core)
    ├── output_buffer.sv
    ├── reliability_monitor.sv
    ├── error_counter.sv
    ├── fault_detector.sv
    ├── adaptive_controller.sv
    └── recovery_controller.sv
```

## 6. Fault-injection connectivity (simulation only)

`tb/fault_injector.sv` binds to **named hierarchical targets** inside the DUT
(`u_core.acc`, `u_core.lane_a.product_q`, `u_core.state`, weights…), applying
`force`/`release` or XOR-overwrite via `deposit`-style assignment at scheduled
cycles. Nothing of it exists in `rtl/` (requirement V-05, checked by grep audit).

## 7. Clock/reset/IO

- Single clock, **100 MHz** (Arty A7 oscillator `E3` = 100 MHz → `create_clock 10.0`).
- Reset: `rst_n`, async assert, sync de-assert (2-FF synchronizer in top).
- Target part (default): **xc7a35ticsg324-1L** (Arty A7-35T). *If the board is
  A7-100T: change `PART` in `sim/*.tcl` to `xc7a100tcsg324-1` and rerun Phase 8
  scripts — parameter is centralized in `sim/common.tcl`.*
- Board I/O (Phase 10 optional): mode LEDs, fault_latched LED, 7-seg status —
  bitstream scope, deferred until core results complete.

## 8. Interfaces (FINAL — supersedes §6 draft)

```systemverilog
// ===== mac_unit =====
// in:  clk, rst_n, a[DATA_W], b[DATA_W], in_valid, acc_clear
// out: result[ACC_W], out_valid, product[2*DATA_W]
// Behavior: result <= acc_clear ? a*b : result + a*b  (1-cycle registered)
//
// ===== input_buffer (FIFO) =====
// in:  wr_data[{a,b}], wr_valid, rd_ready
// out: rd_data[{a,b}], rd_valid, empty, full  (+ count)
//
// ===== output_buffer =====
// in:  wr_data[ACC_W], wr_valid, commit_block, rd_ready
// out: rd_data[ACC_W], rd_valid(=out_valid), commit  (commit = out_valid && !commit_block)
//
// ===== reliability_monitor =====
// in:  clk,rst_n, acc[ACC_W], acc_parity, result[ACC_W], core_state[2:0],
//      busy, fine_en, range_valid  (range_valid: result meaningful this cycle)
// out: err_pulse, err_class[1:0] (01 datapath, 10 control, 11 liveness),
//      wd_timeout
//
// ===== error_counter =====
// in:  clk,rst_n, err_pulse, clear, threshold[7:0] (=TH_ERR), sev_threshold (=TH_SEV)
// out: count[7:0], thresh_hit, sev_hit   (clear zeroes count; sticky flags cleared by `clear`)
//
// ===== fault_detector =====
// in:  clk,rst_n, err_pulse, err_class[1:0], dmr_mismatch, temporal_mismatch, wd_timeout,
//      illegal_state
// out: detected, severe, class_code[1:0]
//
// ===== adaptive_controller =====
// in:  clk,rst_n, thresh_hit, sev_hit, severe, clean_tick(commit & !err), wd_timeout,
//      recovery_ok, latched_clr, FORCE_PROTECTED, MONITOR_EN
// out: mode[1:0] (00 N,01 M,10 P,11 R), prot_en, monitor_fine, recovery_req,
//      fault_latched
// Params: TH_ERR, H_CLEAN, N_QUIET (counters here), REC_MAX handled in recovery
//
// ===== recovery_controller =====
// in:  clk,rst_n, recovery_req, replay_done, verify_ok, clear
// out: replay_active, attempt[1:0], recovery_ok, commit_block
//
// ===== top_module =====
// in:  clk, rst_n, in_a[DATA_W], in_b[DATA_W], in_valid, out_ready, clear_latched
// out: out_result[ACC_W], out_valid, mode[1:0], err_count[7:0], fault_latched,
//      protection_active (debug)
```

## 8.1 Error-class encoding (fault classification requirement)

| `err_class` | Class | Sources |
|---|---|---|
| `2'b01` | datapath | range violation, parity mismatch, DMR/temporal mismatch |
| `2'b10` | control | illegal core FSM state |
| `2'b11` | liveness | watchdog timeout |
| `2'b00` | none | idle |

## 9. Design decisions log

| # | Decision | Rationale |
|---|---|---|
| D-1 | Single MAC lane + checkpoint array (not full systolic array) | verifiability; project studies *reliability mechanisms*, not peak throughput |
| D-2 | Operands checkpointed in FF array | serves triple duty: temporal-redundancy source, replay source, recovery without BRAM |
| D-3 | B = C1 with forced mode | isolates policy effect (charter §4) |
| D-4 | err_count cleared on escalation to PROTECTED | enables de-escalation condition `err_count==0` (spec T-6) |
| D-5 | Parity scheme: stored parity bit updated with acc; checker = `^acc != stored` | detects odd-bit flips in accumulator with 1 FF + XOR tree |
| D-6 | Arty A7 100 MHz clock | board oscillator; matches spec MT-08 target |
