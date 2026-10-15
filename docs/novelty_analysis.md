# PHASE 1 — Novelty and Related-Work Analysis

**Project:** Runtime-Adaptive Reliability-Aware AI Accelerator for FPGA
**Date of literature search:** 2026-09-24
**Search method:** arXiv API (export.arxiv.org), queries covering: fault-tolerant
accelerators on FPGA, adaptive protection for neural-network accelerators, soft errors
in DNN accelerators, SEU + FPGA + ML, adaptive fault tolerance + FPGA, ABFT +
accelerator, dynamic TMR + accelerator, RTL fault injection + neural network.

> **Honesty note:** arXiv does not cover all IEEE/ACM venues. Before publication,
> this search must be repeated on IEEE Xplore / Google Scholar / ACM DL. All claims
> below are limited to what was actually found in this search.

---

## 1. The research problem (beginner explanation)

### 1.1 What is a "fault" in an FPGA?

An FPGA is built from look-up tables (LUTs), flip-flops (FFs), DSP blocks and block
RAMs (BRAMs). Configuration SRAM cells decide what every LUT does. A charged particle
(radiation), a voltage glitch, or aging can flip one of those bits or a data
flip-flop. The result is a **Single-Event Upset (SEU)**: the circuit still runs, but
one bit now holds the wrong value. In an AI accelerator that bit may live in:

- the **accumulator** of a MAC (multiply-accumulate) unit → wrong arithmetic result,
- a **weight register** → wrong model parameter,
- a **control FSM state** → wrong sequencing, stall, or lockup,
- a **pointer/counter** → wrong memory address.

This class of failure is dangerous precisely because nothing "crashes" — the
accelerator keeps producing **confident but wrong** outputs (silent data corruption).

### 1.2 How do people protect against it today?

Standard techniques (all classical, decades of literature):

| Technique | Idea | Cost |
|---|---|---|
| **TMR** (Triple Modular Redundancy) | 3 copies + majority vote | ~3× area/power |
| **DMR** (Dual Modular Redundancy / lockstep) | 2 copies + comparator, detects but does not correct | ~2× area/power |
| **ECC / parity** on memories | correct/detect bit flips in BRAM/registers | parity tree + latency |
| **ABFT** (Algorithm-Based Fault Tolerance) | checksums computed by the algorithm itself (e.g., row/column sums of a matrix product) | small, but only catches some arithmetic errors |
| **Checkpoint / rollback** | save state, restart on error | storage + restart latency |
| **Watchdog / liveness monitor** | detect stalls/timeouts | tiny, but detects only control faults |

### 1.3 The cost problem these techniques create

Protection is **always paid for, whether or not faults occur**. Soft-error rates in
terrestrial FPGA environments are low (roughly orders of magnitude rarer than
clock cycles). So an always-protected accelerator spends 100% of its life paying
TMR/DMR area, power and possibly timing overhead to defend against events that
happen rarely. Meanwhile an *unprotected* accelerator is fast and cheap but can
silently corrupt results.

**The research idea:** make protection *runtime-adaptive* — watch the actual error
rate with an on-chip monitor, and only pay the protection cost during periods when
errors are (or are likely to be) present.

The research question is explicitly comparative:

> Can runtime adaptation reduce the hardware/energy overhead of continuous fault
> protection while maintaining useful fault detection and recovery capability?

"Useful" and "reduce" must both be **measured**, not asserted.

---

## 2. Related work found in the search (with sources)

### 2.1 Closest existing work — runtime-adaptive reliability on AI accelerators

1. **WARD — Runtime Workload-Adaptive ViT Framework for Dependable Edge AI**
   (Taheri et al., arXiv:2609.17556, Jul 2026)
   Four runtime operating modes (Full-Precision / Low-Power / High-Reliability /
   Adaptive), implemented on a lightweight FPGA accelerator with runtime mode
   scheduling hardware. Reports <5% area overhead, mode transitions in a few clock
   cycles, 1.79% network-level failure rate under high BER.
   → **This is the closest work to the proposed project. It occupies the same
   problem space: runtime-selectable operating modes including a reliability mode,
   on an FPGA AI accelerator.**

2. **ProWAFT — Workload-Aware and Dynamic Fault Tolerance in FPGA-Based CNN
   Accelerators** (Chen et al., arXiv:2607.01602, Jul 2026)
   Uses **partial reconfiguration** to selectively apply TMR to reconfigurable
   partitions based on workload criticality; evaluated on ZCU104 with time-varying
   SEU injection; beats static TMR and reactive reconfiguration on a composite
   latency/energy/reliability cost.
   → **Dynamic (workload-aware) protection selection on FPGA CNN accelerators
   already exists — at partial-reconfiguration time scale.**

3. **EIR — Emulated Integrity Replica / hierarchical digital twins**
   (Malik et al., arXiv:2607.12298, Jul 2026)
   Detection (coarse "Rabbit" model) + recovery (fine "Tortoise" model) hosted on
   the underutilized PS of an FPGA SoC instead of duplicating PL fabric; checkpointed
   recovery; compared against a DMR baseline.

4. **BLINK — BN-based integrity checkpoints for weight corruption**
   (Khan et al., arXiv:2609.06781, Sep 2026)
   Runtime *detection and mitigation* of weight bit-flips from activation statistics;
   autonomous, no host interaction; reported <2% latency, 0.53% compute overhead.

5. **DRIFT — resilience-aware DVFS + selective rollback ABFT for diffusion models**
   (Wen et al., DAC 2026, arXiv:2604.09073)
   Protects only error-sensitive blocks/timesteps; adapts voltage/frequency to the
   model's inherent fault tolerance.

6. **ReaLM — statistical ABFT for LLM inference** (Xie et al., DAC 2025,
   arXiv:2503.24053)
   Characterizes LLM fault tolerance by injection study, then minimizes *recovery*;
   online error-statistics collection circuits; reported 1.42% area / 1.79% power
   overhead.

### 2.2 FPGA fault detection for accelerators (non-adaptive or offline-adaptive)

7. **TMR survey** (Flad et al., arXiv:2603.14411, Mar 2026) — documents the shift
   toward "Mixed and Adaptive TMR ... for dynamic and error-tolerant applications,
   such as AI acceleration", and explicitly lists research gaps: **"the absence of
   high-level toolchains for dynamic reconfiguration"** and **"open-source tools for
   adaptive fault tolerance"**.
8. **Selective protection on Arm Ethos-U55** (Tyagi et al., arXiv:2404.09317, 2024)
   — large-scale RTL fault injection + offline selection of *which* structures to
   harden; meets ASIL-D at 38% area overhead vs 100% for DCLS. **Adaptation is
   decided offline at design time, not at runtime.**
9. **Systolic-array DNN accelerator SEU analysis** (Jonckers et al.,
   arXiv:2405.15381, 2024; arXiv:2512.00028, 2025) — RTL fault injection campaigns,
   sensitivity of register groups, mitigation strategy derivation.
10. **FPGA emulation + fault injection for CNN inference accelerators**
    (Masar, Mrazek, Sekanina, DATE 2025, arXiv:2501.12818) — injects faults into
    **MAC multipliers of NVDLA**, order-of-magnitude faster than software FI.
11. **RTL fault injection of a deployed GNN trigger (Belle II)**
    (Sotiropoulos et al., arXiv:2607.03153, 2026) — 1.44M SEUs; shows that
    **output-only observation vs liveness monitoring give mean-time-to-failure
    estimates differing by up to 78.7%**. Directly relevant to how our reliability
    monitor must observe the design.
12. **ABFT family:** Flash-ABFT for attention (arXiv:2507.16676, 5.3% area),
    GCN-ABFT (arXiv:2412.18534), error checking for sparse systolic arrays
    (arXiv:2402.10850). These are *always-on* detectors, not adaptive.
13. **Oobleck** (Wilks et al., arXiv:2506.22654, 2025) — modular-acceleration-based
    fault tolerance, low area overhead; datacenter (not radiation/SEU) framing.
14. **Efficient Error-Tolerant QNN Accelerators** (Gambardella et al., DFT 2019,
    arXiv:1912.07394) — selective channel replication instead of TMR; fault-aware PE
    scheduling. Early example of *partial/selective* protection.
15. **COTS space payload FT combination** (Leon et al., VLSI-SoC 2022,
    arXiv:2506.12971) — memory scrubbing + PR + TMR + watchdogs combined.

---

## 3. Existing work vs proposed work

| Dimension | Existing work | Proposed project |
|---|---|---|
| Runtime-selectable reliability modes on an FPGA AI accelerator | **Exists** (WARD, 4 modes; ProWAFT, workload-aware PR) | Not claimed as novel |
| Dynamic selection of protection *mechanism* | Exists at partial-reconfig granularity (ProWAFT) | We work at **cycle-granularity RTL control**, no PR |
| Adaptation of *recovery intensity* | Exists (ReaLM, DRIFT, BLINK) | We adapt **protection level**, not just recovery |
| Offline selective protection via FI campaign | Exists (Ethos-U55, systolic SEU studies) | We adapt **at runtime** from an on-chip monitor |
| RTL reliability monitor + error counter + threshold + fault classification feeding an FSM | Individual pieces exist (watchdogs, counters, checkers) | Integrated, small, fully synthesizable, **self-contained monitor→policy→protection loop** |
| Controlled **three-baseline** PPA study (normal / always-protected / adaptive) on **identical part, constraints, workload** with **protection-active time** as a metric | **Not found in this search** | **Primary contribution** |
| Coverage-vs-overhead tradeoff curve driven by tunable thresholds/hysteresis | Not found as a hardware-measured curve | Secondary contribution |

### 3.1 The precise technical gap

From this search, the defensible gap is **not** "runtime-adaptive reliability does
not exist" — WARD and ProWAFT show it does. The gap is:

> **No small, fully RTL-synthesizable, self-contained accelerator was found in which
> a cycle-granular reliability monitor, a threshold/hysteresis policy FSM, and a
> protection-escalation datapath are implemented together and evaluated in a
> controlled three-baseline study (normal vs always-protected vs adaptive) under an
> identical FPGA part, constraints and workload — reporting protection-active time,
> detection coverage and recovery latency alongside standard PPA metrics.**

Supporting observations:
- WARD adapts at *application/subnetwork* level (different precision subnetworks),
  not at the level of a datapath protection mechanism inside a MAC pipeline.
- ProWAFT adapts via **partial reconfiguration** (millisecond-scale, build/region
  constrained); we target **cycle-scale** mode changes with no PR.
- Ethos-U55 / systolic studies decide protection **offline** from fault campaigns.
- ReaLM/DRIFT adapt *how much to recover*, not *which protection level is active*.
- The TMR survey itself lists adaptive-FT tooling as an open gap.

### 3.2 What we must NOT claim

- ❌ "First runtime-adaptive reliability AI accelerator" (WARD, ProWAFT).
- ❌ "Novel fault injection method" (many prior RTL FI campaigns).
- ❌ "Novel error detection scheme" (ABFT, parity, DMR all classical).
- ❌ Any numerical result not produced by our own simulation/synthesis/implementation.

---

## 4. Three candidate architectures

### Architecture A — Mode-Gated Spatial Redundancy ("gated DMR")

Protection = a second, lockstep MAC copy + comparator, physically instantiated
*always*, but its clock/enable is gated by the adaptive controller outside
PROTECTED mode. Monitor (parity/range check) always runs cheaply.

- **Pros:** simplest RTL; same protection mechanism as the always-protected
  baseline, so *adaptation itself* is the only experimental variable (clean
  methodology); detection is fast and deterministic; easy fault injection.
- **Limitation (important, teaches a real FPGA lesson):** with a static bitstream,
  LUT/FF/DSP counts are fixed at build time. Gating saves **dynamic power** and can
  save **throughput overhead**, but **does not reduce area** vs the always-protected
  build — the redundant logic is still in the fabric. Fmax is also set by the worst
  case path of the whole build, so gating alone rarely changes Fmax.
- **Measurable claims:** dynamic power ↓, throughput ↑ in clean periods,
  protection-active time; area ≈ always-protected (honest negative result).

### Architecture B — Escalating Hybrid: light detector + temporal redundancy on demand **(RECOMMENDED)**

Protection **mechanism changes per mode**, not just its enable:

- `NORMAL` — bare pipeline (identical to baseline A).
- `MONITORED` — cheap always-on checks (accumulator range check + residue/parity
  check on the MAC chain); detection only, no redundancy cost.
- `PROTECTED` — on threshold crossing, each dot-product result is **recomputed in a
  temporal shadow pass and compared** (temporal redundancy), so protection costs
  *extra cycles*, not extra multipliers.
- `RECOVERY` — flush pipeline, replay from a small checkpoint buffer, then
  de-escalate after N clean results (hysteresis).

- **Pros:** genuinely **three different points** on the area/performance/coverage
  triangle — adaptive design lands *between* normal and always-protected in area,
  and pays throughput only while protection is active; makes
  "protection-active time" the natural energy metric; no partial reconfiguration;
  feasible for one student in RTL.
- **Limitations:** the always-protected baseline uses spatial redundancy while the
  adaptive design uses temporal redundancy → *mechanism* differs, not only
  *activation policy* (must be stated as a threat to validity; mitigate by also
  implementing Architecture A as a fourth variant if time allows); light detector
  coverage < 100% and must be measured honestly; recovery needs a checkpoint buffer
  (a few registers or a small BRAM).

### Architecture C — Partial-Reconfiguration Adaptive (ProWAFT-style)

Protection logic instantiated only when needed by reconfiguring FPGA regions.

- **Pros:** the only option with **real area savings vs always-protected** (fabric
  itself changes); closest to "reduce area overhead" in the strongest sense.
- **Limitations:** PR flow (partition definitions, black-box cells, checkpointing)
  is substantially harder; transitions are millisecond-scale, contradicting a
  cycle-granular adaptation claim; board/part dependent; large build times; high
  risk for a learning project.
- **Recommendation:** document as **future work**; optionally prototype only if
  Phases 8–14 complete early.

### Recommendation

**Build Architecture B as the proposed design**, with Architecture A optional as a
fourth variant for the methodological control. This gives a defensible, measurable
story within a student FPGA project scope, and it lets us honestly discuss *why*
area savings are hard on static FPGAs — a genuinely interesting engineering
discussion rather than an inflated claim.

---

## 5. Exactly what can be claimed as the contribution

**Primary (methodological + architectural):**
> A compact, fully synthesizable RTL implementation of a closed-loop
> *monitor → threshold/hysteresis policy FSM → protection-level escalation*
> system for an INT8 MAC accelerator, evaluated in a controlled three-baseline
> study (normal / always-protected / runtime-adaptive) under identical device,
> constraints and workload, reporting protection-active time, fault-detection
> coverage, recovery latency and PPA together.

**Secondary:**
> A measured coverage/overhead tradeoff curve as a function of monitor threshold
> and hysteresis settings (sweep in fault-injection simulation).

**Explicit non-claims:** novelty of runtime-adaptive reliability itself, novelty of
the fault-injection method, novelty of DMR/ABFT/parity detection, and any
application-scale (full CNN) accuracy claims.

---

## 6. Phase 1 status / gate to Phase 2

- [x] Literature search executed (arXiv, 2026-09-24)
- [x] Existing vs proposed comparison table
- [x] Precise gap defined
- [x] 3 architectures analyzed with pros/cons
- [x] Architecture B recommended; contribution scoped
- [ ] **Before publication:** repeat search on IEEE Xplore / Google Scholar and add
      citations that arXiv does not cover (e.g., FPGA ` adaptive reliability`
      sessions at FPL/FCCM/DATE, radiation-effects workshops RADECS/NSREC).

**Gate:** proceed to Phase 2 (Requirements Specification) only after the reader
accepts the scoped contribution in Section 5.
