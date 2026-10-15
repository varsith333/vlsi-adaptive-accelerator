# Runtime-Adaptive Reliability-Aware AI Accelerator (FPGA)

An INT8 dot-product AI accelerator with a runtime-adaptive reliability
subsystem, implemented in synthesizable SystemVerilog and evaluated on
AMD/Xilinx Artix-7 (`xc7a35ticsg324-1L`) with Vivado 2025.2.

One parameterized RTL builds four variants that are compared apples-to-apples:

| Variant | Protection | Correction strategy |
|---------|------------|---------------------|
| **A** | none (baseline) | none - the "0% protection cost" reference |
| **B** | always-on DMR | spatial: second MAC lane compares every result |
| **C1** | adaptive DMR | spatial, escalated only when faults strike |
| **C2** | adaptive temporal | recomputes the vector from an operand checkpoint |

## Repository layout

```
rtl/      14 SystemVerilog modules (datapath + reliability subsystem + 4 wrappers)
tb/       9 testbenches: golden system test, unit tests, fault-injection campaign
sim/      Tcl/PowerShell flows + XDC constraints (100 MHz characterization, 75 MHz signoff)
docs/     requirements, architecture, verification plan, experiment plan, final report
reports/  measured evidence: synthesis/timing, fault injection, power (CSV + Vivado RPT)
```

## Headline results (measured, see docs/final_report.md)

- Golden system test: **PASS** - 4 variants x 1200 vectors, fault injection
  directed at protected variants, detection latency 1-2 cycles (limit: <= 2),
  zero golden mismatches.
- Fault-injection campaign: **80,000 injections** (4 classes x 5 seeds x configs).
  Arithmetic faults flagged *before* a wrong result: **A = 0.0%**,
  **B/C1/C2 = 100.0%** at ~1 cycle average detection latency.
- Timing signoff at 75 MHz: WNS **+0.166 / +0.067 / +0.017 / +0.066 ns**
  (A/B/C1/C2), TNS 0. The 100 MHz characterization fails and is reported
  honestly with per-path root cause (see final report sections 6-7).
- Area cost of protection (LUTs vs A): **+100% (B), +113% (C1), +83% (C2)**.
- Throughput (committed results / 1000 cycles): **90.9 / 90.9 / 90.8 / 87.4**.
- Power (75 MHz, SAIF-annotated, coverage disclosed 7-12% of nets):
  **93 / 99 / 98 / 96 mW** - single-digit-percent protection overhead.

## Reproducing

Requires Vivado 2025.2 (Windows). From the `sim\` folder:

```powershell
powershell -ExecutionPolicy Bypass -File run_synth.ps1     # synth + impl, timing CSVs
powershell -ExecutionPolicy Bypass -File run_sim.ps1 -Tb tb_top_module   # golden test
powershell -ExecutionPolicy Bypass -File run_fi.ps1        # fault-injection campaign
powershell -ExecutionPolicy Bypass -File run_power.ps1     # power reports
```

The scripts stage sources to a space-free temp directory before invoking
Vivado (the containing folder path may contain spaces).

## Documentation

- `docs/final_report.md` - full results, deviations, limitations, repro commands
- `docs/requirements_spec.md` - requirements (F/MT/N/V numbering used throughout)
- `docs/verification_plan.md` - testbench strategy and assertions (N-07 amendment)
- `docs/experiment_plan.md` - measurement methodology and threats to validity

## Scope and limitations (short version)

RTL-level fault model (not bitstream SEUs), simulation-only verification,
single clock domain, partial SAIF annotation, and C1/C2 detect-but-do-not-
prevent every small arithmetic fault. Full discussion with numbers:
`docs/final_report.md` sections 5.3 and 12.
