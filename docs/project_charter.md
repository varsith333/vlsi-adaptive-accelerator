# PROJECT CHARTER (RECONSTRUCTED — v2.0)

**Supersedes:** the original project outline and the problem list from the Phase 1 review.
**Purpose:** a project definition with every identified problem *designed out*, not deferred.

> Reading note: "no bugs and faults" here means **no defects in the project definition**
> (flawed novelty claim, unmeasurable goals, infeasible scope, invalid comparisons).
> Fault injection remains — it is the measurement instrument of this research.

---

## 1. Corrected title

**Before:** "Runtime-Adaptive Reliability-Aware AI Accelerator for FPGA"
(implies a novelty claim that WARD/ProWAFT already occupy)

**After:**
> **"Closed-Loop Runtime Protection Scaling for an FPGA Dot-Product Engine:
> A Controlled Three-Baseline PPA and Fault-Injection Study"**

Why this title is safe:
- "Closed-loop runtime protection scaling" describes *our specific mechanism*, not
  the already-published general idea of adaptive reliability.
- "Dot-product engine" is honest about what the hardware computes (fixes Problem 6).
- "Controlled three-baseline study" names the actual contribution (the gap found in Phase 1).

---

## 2. Problem statement (defensible version)

Always-on protection (DMR/TMR, ABFT, ECC) of FPGA accelerator datapaths pays
continuous area, power and performance cost against rarely occurring faults, while
an unprotected datapath silently corrupts results. Prior work already adapts
reliability at *application level* (WARD), at *partial-reconfiguration time scale*
(ProWAFT), or at *design time* via offline fault campaigns (Ethos-U55-style selective
protection). **Not found in the arXiv-based Phase 1 search:** a small, fully
synthesizable, cycle-granular *monitor → threshold/hysteresis policy FSM →
protection-level escalation* loop, evaluated under an identical FPGA part,
constraints and workload against both a normal and an always-protected baseline,
reporting protection-active time and detection coverage together with PPA.

**Research question (unchanged, measurable):**
> Under a defined simulation fault model, does cycle-granular runtime scaling of
> protection level reduce dynamic power and throughput overhead relative to an
> always-protected implementation, while maintaining a measured fault-detection
> coverage and bounded recovery latency — and what coverage/overhead tradeoff do
> monitor threshold and hysteresis settings produce?

Every underlined term has a numeric definition in Section 6.

---

## 3. Claims and non-claims (locked)

**We claim (and will measure):**
1. A closed RTL loop: reliability monitor → error counter with configurable
   threshold + hysteresis → 4-state policy FSM → protection escalation.
2. A controlled three-baseline comparison (A: normal, B: always-protected,
   C: runtime-adaptive) on **the same part, same constraints, same workload**,
   reporting LUT/FF/DSP/BRAM, Fmax, WNS, power (SAIF-based), latency, throughput.
3. Protection-active time (%) and detection coverage (%) under a documented
   fault-injection model, plus recovery latency in cycles.
4. A threshold/hysteresis sweep producing a coverage-vs-overhead tradeoff curve.

**We never claim:**
- novelty of runtime-adaptive reliability itself (WARD, ProWAFT exist — cited),
- novelty of DMR/TMR/ABFT/parity or of RTL fault injection (classical, cited),
- real radiation/soft-error rates — all results are **under our defined fault model**,
- any number not produced by our own simulation/synthesis/implementation or a
  documented calculation.

---

## 4. Architecture decision (fixes Problem 2 — the area/validity issue)

**Build two adaptive variants so mechanism-vs-policy confound is controlled:**

| Variant | Role | Protection mechanism | What it isolates |
|---|---|---|---|
| **A — NORMAL** | baseline | none | reference PPA |
| **B — ALWAYS** | baseline | spatial DMR (duplicate MAC + comparator, always on) | cost of continuous protection |
| **C1 — ADAPTIVE-POLICY** | proposed | *identical* spatial DMR, runtime-gated by FSM | **pure effect of adaptation policy** (power/perf only; area ≈ B — reported honestly) |
| **C2 — ADAPTIVE-TEMPORAL** | proposed | FSM escalates to temporal recompute-and-compare (no duplicate MAC) | **area-reduction path** (cycles, not silicon) |

This turns the previous problem into an explicit experiment: C1 vs B measures
policy effect with mechanism held constant; C2 vs B measures mechanism substitution.
Area claims come only from C2; power/performance claims from both. Partial
reconfiguration (former Architecture C) is documented as future work, not attempted.

## 5. Scope decision (fixes Problem 5 — 17-phase overload)

**MVP phase plan (10 phases), ordered with hard gates:**

| Phase | Content | Gate to proceed |
|---|---|---|
| P1 | Literature/novelty analysis | ✅ done (`docs/novelty_analysis.md`) |
| P2 | Requirements + fault model + metric definitions | doc reviewed, all terms numeric |
| P3 | Architecture (block diagram, mode table, interfaces) | signed off |
| P4 | RTL: MAC core + buffers + control FSM | unit TB passes |
| P5 | RTL: monitor, counter, detector, FSMs (A/B/C1/C2 tops) | unit TBs pass |
| P6 | System-level simulation, all variants, golden vectors | 100% match vs reference model |
| P7 | Fault-injection campaign (simulator script, N injections) | coverage/recovery numbers produced |
| P8 | Vivado synthesis + implementation ×4 variants | timing met, reports collected |
| P9 | Power (SAIF from gate-level sim) + PPA comparison table | all cells filled from reports |
| P10 | Analysis + documentation + presentation | draft complete |

- **Deferred (stretch, only if P1–P10 finish early):** bitstream/board validation,
  partial reconfiguration, MNIST-scale workload.
- **Cut from scope:** large buffers/BRAM, full CNN framing, PR flow.

## 6. Measurement definitions (fixes Problems 3 & 4 — noise and coverage)

| Metric | Definition (numeric, fixed in P2) |
|---|---|
| **Protection-active time** | cycles in PROTECTED or RECOVERY ÷ total measured cycles × 100 (%) |
| **Detection coverage** | injected faults producing a monitor flag before faulty output is committed ÷ total injected faults × 100 (%) — always reported with fault model + observation points |
| **Recovery latency** | cycles from fault detection flag → first correct committed output after recovery |
| **Power** | Vivado post-implementation estimate **with SAIF switching activity** from gate-level simulation of a fixed workload trace; reported as % overhead vs baseline A, not absolute µW alone |
| **Overhead metrics** | always reported as % vs baseline A, so a small design's absolute numbers can't mislead |
| **Fault model** | simulation-only injector, 4 classes: MAC result flip, register bit-flip, weight bit-flip, FSM state disturbance; injection points, timing, count (≥1000/campaign), and seed list documented in verification plan; observation at *committed outputs and liveness*, not output-only (per Belle II finding) |

## 7. Risk register — problem → designed-out resolution

| # | Identified problem | Resolution built into v2.0 |
|---|---|---|
| 1 | Idea already published (WARD, ProWAFT) | Title/claims scoped to closed-loop mechanism + controlled study; WARD/ProWAFT cited as related work |
| 2 | Area claim impossible with static bitstream under gating | Two adaptive variants: C1 (policy, power/perf claims) + C2 (temporal, area claims); PR dropped to future work |
| 3 | Power numbers noise on tiny design | Overhead reported as % vs baseline; SAIF-based power; design sized so protection is a meaningful fraction (array of ≥4 MACs, finalized in P3) |
| 4 | Coverage <100%, simulated faults only | Coverage defined numerically with fault model disclaimer; multi-point observation |
| 5 | 17-phase overload | 10-phase MVP with hard gates; board/PR/MNIST deferred |
| 6 | "AI accelerator" oversell | Title says "dot-product engine"; AI framing as context only |
| 7 | Unknown tooling/board | P2 gate: record Vivado version, target part, board availability; if no board, scope is simulation+synthesis+implementation only (already sufficient) |
| 8 | arXiv-only literature gap | Flagged in novelty doc: repeat on IEEE Xplore/Google Scholar before the final related-work chapter (does not block P2–P9) |

## 8. Inputs (environment survey done 2026-09-25)

1. **Vivado:** version **2025.2** installed at `D:\Xilinx\2025.2\Vivado\bin\vivado.bat`
   (device data includes artix7, spartan7, zynq families → Artix-7 parts usable for synthesis)
2. **Editor:** VS Code installed.
3. **Target FPGA part:** TBD — default candidate `xc7a35tcsg324-1` (Basys3-class Artix-7);
   confirm actual board when known. Synthesis can proceed with the candidate part even
   without a physical board.
4. 10-phase MVP scope: pending user confirmation.
