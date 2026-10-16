#!/usr/bin/env python3
"""
Runtime-Adaptive Reliability-Aware AI Accelerator (FPGA)
--------------------------------------------------------
Parses the VCD produced by:
    powershell -File sim/run_sim.ps1 -Tb tb_top_module -Dump
and renders the waveform screenshots used in README.md.

Outputs (into docs/img/):
    waveform_overview.png          protection mode of all four variants
    waveform_fault_detection.png   variant B: parity fault flagged by the
                                   monitor in ~1 cycle (err_count 0->1->2)
    waveform_escalation.png        variants C1/C2: adaptive escalation
                                   NORMAL -> RECOVERY -> PROTECTED -> MONITORED

Run from the project root:   python tools/plot_waveforms.py
"""

import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ------------------------------------------------------------------ paths
ROOT = Path(__file__).resolve().parent.parent
VCD = ROOT / "build" / "tb_top_module.vcd"
IMG = ROOT / "docs" / "img"
IMG.mkdir(parents=True, exist_ok=True)

MODE_NAMES = {0: "NORMAL", 1: "MONITORED", 2: "PROTECTED", 3: "RECOVERY"}
MODE_COLORS = {"A": "#888888", "B": "#d62728", "C1": "#1f77b4", "C2": "#2ca02c"}
UNIT_NS = {"s": 1e9, "ms": 1e6, "us": 1e3, "ns": 1.0, "ps": 1e-3, "fs": 1e-6}


# ------------------------------------------------------------- VCD parser
def parse_vcd(path):
    """Return (scale_to_ns, {signal_name: [(time_raw, value_int), ...]}).

    Only variables in the testbench's own scope are collected (the dump uses
    $dumpvars(1, tb_top_module)), so names are unique and flat.
    """
    scale_ns = None
    ts_pending = False
    signals = {}   # name -> list of (time_raw, int_value)
    ids = {}       # identifier code -> name
    scope = []     # scope stack
    tb = "tb_top_module"
    t = 0
    in_defs = True

    with open(path, "r", errors="replace") as f:
        for line in f:
            s = line.strip()
            if in_defs:
                if s.startswith("$timescale"):
                    ts_pending = "$end" not in s
                    scale_ns = _parse_timescale(s) or scale_ns
                elif ts_pending:
                    scale_ns = _parse_timescale(s) or scale_ns
                    ts_pending = False
                elif s.startswith("$scope"):
                    scope.append(s.split()[2])
                elif s.startswith("$upscope"):
                    if scope:
                        scope.pop()
                elif s.startswith("$var"):
                    # $var wire 2 " m_B [1:0] $end   (range may be absent)
                    parts = s.split()
                    code, name = parts[3], parts[4]
                    if len(scope) == 1 and scope[0] == tb:
                        ids[code] = name
                elif s.startswith("$enddefinitions"):
                    in_defs = False
                continue

            if not s:
                continue
            if s[0] == "#":
                t = int(s[1:])
                continue
            if s.startswith("$"):          # $dumpvars / $end markers
                continue
            if s[0] in "bB":               # vector: b0101 <code>
                parts = s.split()
                if len(parts) == 2 and parts[1] in ids:
                    signals.setdefault(ids[parts[1]], []).append(
                        (t, _to_int(parts[0][1:])))
            elif s[0] in "01xXzZ":         # scalar: 0<code>
                code = s[1:]
                if code in ids:
                    signals.setdefault(ids[code], []).append((t, _to_int(s[0])))
    if scale_ns is None:
        raise SystemExit(f"no $timescale found in {path}")
    return scale_ns, signals


def _parse_timescale(s):
    m = re.search(r"(\d+(?:\.\d+)?)\s*(ms|us|ns|ps|fs|s)\b", s)
    if m:
        return float(m.group(1)) * UNIT_NS[m.group(2)]
    return None


def _to_int(bits):
    return int("".join("0" if c in "xXzZ" else c for c in bits), 2) if bits else 0


# ----------------------------------------------------- time-window helpers
def ns_to_raw(ns, scale_ns):
    """Convert nanoseconds to raw VCD time units."""
    return int(ns / scale_ns)


def raw_to_ns(t_raw, scale_ns):
    return t_raw * scale_ns


def step_xy(sig, t_end_raw, scale_ns):
    """Step-plot coordinates from (t_raw, value) changes, x in nanoseconds."""
    if not sig:
        return [], []
    xs = [raw_to_ns(t, scale_ns) for t, _ in sig]
    ys = [v for _, v in sig]
    xs.append(raw_to_ns(t_end_raw, scale_ns))
    ys.append(ys[-1])
    return xs, ys


def first_rise(sig):
    """Raw time of the first 0->1 transition, or None."""
    for i in range(1, len(sig)):
        if sig[i - 1][1] == 0 and sig[i][1] == 1:
            return sig[i][0]
    return None


def time_when(sig, pred, after_raw=0):
    for t_raw, v in sig:
        if t_raw >= after_raw and pred(v):
            return t_raw
    return None


# ------------------------------------------------------------------ plots
def _style(ax, label, color="#333333"):
    ax.set_ylabel(label, fontsize=9, color=color, rotation=0, ha="right", va="center")
    ax.grid(True, axis="x", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)


def _mode_axis(ax):
    ax.set_yticks(list(MODE_NAMES))
    ax.set_yticklabels([MODE_NAMES[i] for i in list(MODE_NAMES)], fontsize=8)
    ax.set_ylim(-0.3, 3.3)


def plot_overview(scale_ns, sig, t_end_raw):
    need = ["m_A", "m_B", "m_C1", "m_C2"]
    missing = [n for n in need if n not in sig]
    if missing:
        print(f"[skip] overview: signals not in VCD: {missing}")
        return None

    fig, axes = plt.subplots(4, 1, figsize=(10, 5.8), dpi=150, sharex=True)
    fig.suptitle("Protection modes over the full run - four variants, 1200 vectors each",
                 fontsize=12, fontweight="bold")
    notes = {
        "A": "baseline: no protection",
        "B": "always-on DMR: always PROTECTED",
        "C1": "adaptive: faults late in the run escalate it",
        "C2": "adaptive: faults late in the run escalate it",
    }
    for ax, var in zip(axes, ("A", "B", "C1", "C2")):
        xs, ys = step_xy(sig[f"m_{var}"], t_end_raw, scale_ns)
        ax.step(xs, ys, where="post", color=MODE_COLORS[var], linewidth=1.4)
        _style(ax, var, MODE_COLORS[var])
        _mode_axis(ax)
        ax.text(0.005, 0.94, notes[var], transform=ax.transAxes, fontsize=7,
                color="#666666", ha="left", va="top")
    axes[-1].set_xlabel("time (ns)", fontsize=9)
    fig.tight_layout(rect=(0.02, 0, 1, 0.95))
    out = IMG / "waveform_overview.png"
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)
    print("wrote", out)
    return out


def plot_fault_zoom(scale_ns, sig, t_end_raw):
    need = ["inj_B", "fr_B", "e_B", "m_B"]
    missing = [n for n in need if n not in sig]
    if missing:
        print(f"[skip] fault zoom: signals not in VCD: {missing}")
        return None

    t0 = first_rise(sig["inj_B"])
    if t0 is None:
        print("[skip] fault zoom: no inj_B rise found")
        return None
    t_det = time_when(sig["e_B"], lambda v: v >= 2) or t0

    # window: 400 ns before the injection until ~1.2 ns*1000 after TH_ERR
    lo = max(0, t0 - ns_to_raw(400, scale_ns))
    hi = min(t_det + ns_to_raw(1200, scale_ns), t_end_raw)

    fig, axes = plt.subplots(4, 1, figsize=(10, 5.6), dpi=150, sharex=True)
    fig.suptitle("Fault detection - variant B (always-on DMR): parity fault "
                 "flagged in ~1 cycle",
                 fontsize=12, fontweight="bold")

    rows = [("inj_B", "inj_B", "#d62728"),
            ("fr_B", "fr_B\n(deposit fired)", "#ff7f0e"),
            ("e_B", "e_B\n(err_count)", "#9467bd"),
            ("m_B", "m_B (mode)", "#2ca02c")]
    for ax, (name, label, color) in zip(axes, rows):
        xs, ys = step_xy(sig[name], t_end_raw, scale_ns)
        ax.step(xs, ys, where="post", color=color, linewidth=1.4)
        _style(ax, label, color)
        ax.set_xlim(lo * scale_ns, hi * scale_ns)

    axes[0].set_yticks([0, 1])
    axes[1].set_yticks([0, 1])
    axes[2].set_yticks([0, 1, 2])
    _mode_axis(axes[3])

    t0_ns = raw_to_ns(t0, scale_ns)
    axes[0].annotate("fault injected", xy=(t0_ns, 1),
                     xytext=(t0_ns - 90, 1.7), fontsize=8, color="#d62728",
                     arrowprops=dict(arrowstyle="->", color="#d62728", lw=1))
    axes[2].annotate("monitor flags\nit (~1 cycle)", xy=(raw_to_ns(t_det, scale_ns), 2),
                     xytext=(raw_to_ns(t_det, scale_ns) + 40, 1.15),
                     fontsize=8, color="#333333",
                     arrowprops=dict(arrowstyle="->", color="#333333", lw=1))
    # B never changes mode (static always-on protection): say so explicitly
    if time_when(sig["m_B"], lambda v: v != 2) is None:
        axes[3].text(raw_to_ns(hi, scale_ns) - 50, 2,
                     "always-on DMR:\nstays PROTECTED", fontsize=7,
                     color="#666666", ha="right", va="center")
    axes[-1].set_xlabel("time (ns)", fontsize=9)
    fig.tight_layout(rect=(0.03, 0, 1, 0.95))
    out = IMG / "waveform_fault_detection.png"
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)
    print("wrote", out)
    return out


def plot_escalation(scale_ns, sig, t_end_raw):
    need = ["m_C1", "m_C2", "e_C1", "e_C2", "inj_C1", "inj_C2"]
    missing = [n for n in need if n not in sig]
    if missing:
        print(f"[skip] escalation: signals not in VCD: {missing}")
        return None

    # first time C1 leaves {NORMAL, MONITORED} = the severe-fault storm
    t_hit = time_when(sig["m_C1"], lambda v: v >= 2)
    if t_hit is None:
        print("[skip] escalation: C1 never escalated")
        return None

    lo = max(0, t_hit - ns_to_raw(1500, scale_ns))
    hi = min(t_hit + ns_to_raw(7800, scale_ns), t_end_raw)

    fig, axes = plt.subplots(4, 1, figsize=(10, 6.2), dpi=150, sharex=True)
    fig.suptitle("Adaptive escalation - variants C1/C2: only the fault storm "
                 "costs protection time",
                 fontsize=12, fontweight="bold")

    # row 1: injections (C1 solid, C2 dashed)
    for name, ls, color in (("inj_C1", "-", "#d62728"), ("inj_C2", "--", "#ff7f0e")):
        xs, ys = step_xy(sig[name], t_end_raw, scale_ns)
        axes[0].step(xs, ys, where="post", linestyle=ls, color=color, linewidth=1.3)
    _style(axes[0], "fault\ninject", "#d62728")
    axes[0].set_yticks([0, 1])
    axes[0].legend(["C1", "C2"], fontsize=7, loc="upper right", ncol=2,
                   framealpha=0.8)

    # row 2: err_count (C1 solid, C2 dashed)
    for name, ls, color in (("e_C1", "-", "#1f77b4"), ("e_C2", "--", "#2ca02c")):
        xs, ys = step_xy(sig[name], t_end_raw, scale_ns)
        axes[1].step(xs, ys, where="post", linestyle=ls, color=color, linewidth=1.3)
    _style(axes[1], "err_\ncount", "#9467bd")
    axes[1].set_yticks([0, 1, 2])
    axes[1].legend(["C1", "C2"], fontsize=7, loc="upper right", ncol=2,
                   framealpha=0.8)

    # rows 3-4: modes
    for ax, var, color in ((axes[2], "C1", MODE_COLORS["C1"]),
                           (axes[3], "C2", MODE_COLORS["C2"])):
        xs, ys = step_xy(sig[f"m_{var}"], t_end_raw, scale_ns)
        ax.step(xs, ys, where="post", color=color, linewidth=1.4)
        _style(ax, var, color)
        _mode_axis(ax)
        ax.set_xlim(lo * scale_ns, hi * scale_ns)

    # annotations on the C1 trace
    t_rec = time_when(sig["m_C1"], lambda v: v == 3)
    if t_rec and lo <= t_rec <= hi:
        axes[2].annotate("severe fault\n-> RECOVERY",
                         xy=(raw_to_ns(t_rec, scale_ns), 3),
                         xytext=(raw_to_ns(t_rec, scale_ns) - 500, 3.55),
                         fontsize=8, color="#7f3fbf",
                         arrowprops=dict(arrowstyle="->", color="#7f3fbf", lw=1))
    t_prot = time_when(sig["m_C1"], lambda v: v == 2, after_raw=t_rec or 0)
    if t_prot and lo <= t_prot <= hi:
        axes[2].annotate("2nd fault hits TH_ERR\n-> PROTECTED",
                         xy=(raw_to_ns(t_prot, scale_ns), 2),
                         xytext=(raw_to_ns(t_prot, scale_ns) + 350, 2.55),
                         fontsize=8, color="#1f77b4",
                         arrowprops=dict(arrowstyle="->", color="#1f77b4", lw=1))
    t_dec = time_when(sig["m_C1"], lambda v: v == 1, after_raw=t_prot or 0)
    if t_dec and lo <= t_dec <= hi:
        axes[2].annotate("H_CLEAN clean results\n-> back to MONITORED",
                         xy=(raw_to_ns(t_dec, scale_ns), 1),
                         xytext=(raw_to_ns(t_dec, scale_ns) - 2200, 1.6),
                         fontsize=8, color="#1f77b4",
                         arrowprops=dict(arrowstyle="->", color="#1f77b4", lw=1))

    axes[-1].set_xlabel("time (ns)", fontsize=9)
    fig.tight_layout(rect=(0.03, 0, 1, 0.95))
    out = IMG / "waveform_escalation.png"
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)
    print("wrote", out)
    return out


def main():
    if not VCD.exists():
        raise SystemExit(
            f"VCD not found: {VCD}\n"
            "Generate it first:\n"
            "  powershell -ExecutionPolicy Bypass -File sim/run_sim.ps1 "
            "-Tb tb_top_module -Dump"
        )
    scale_ns, sig = parse_vcd(VCD)
    print(f"timescale: {scale_ns} ns/tick; {len(sig)} tb-scope signals")

    t_end_raw = max((t for ch in sig.values() for t, _ in ch), default=0)
    plot_overview(scale_ns, sig, t_end_raw)
    plot_fault_zoom(scale_ns, sig, t_end_raw)
    plot_escalation(scale_ns, sig, t_end_raw)


if __name__ == "__main__":
    main()
