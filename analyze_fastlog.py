#!/usr/bin/env python3
"""
Regatron fast-log analyzer
==========================
Reads one or more regatron_fastlog_*.csv files and produces per session:
  - overview plot (V/I/P over the whole session, events shaded)
  - one zoom plot per detected event (setpoints shown as staircase)
  - polarization curve (V vs I) from the active samples only
  - plateau statistics CSV (mean V/I/P per commanded setpoint)

Event windows are AUTO-DETECTED from the measured current magnitude, so the
same script works for any simulation run and any real-hardware session
without editing hardcoded times.

Usage:
    python3 analyze_fastlog.py bridge_logs/regatron_fastlog_20260917T152855.csv
    python3 analyze_fastlog.py bridge_logs/*.csv --threshold-a 0.5 --out reports/

Columns expected (bridge fast-log format):
    timestamp_iso, epoch_s, mode, commanded_value, commanded_limit,
    voltage_v, raw_voltage_v, current_signed_a, current_mag_a,
    power_w, output_on, has_errors, has_warnings, estop_latched
Missing optional columns degrade gracefully.
"""

import argparse
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

COLORS = {"v": "tab:blue", "i": "tab:orange", "p": "tab:green"}


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def load_fastlog(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    df.columns = [c.strip() for c in df.columns]

    required = {"timestamp_iso", "voltage_v", "current_signed_a", "power_w", "mode"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"{csv_path}: missing required columns {sorted(missing)}")

    df["timestamp"] = pd.to_datetime(df["timestamp_iso"], format="ISO8601")
    df["time_s"] = (df["timestamp"] - df["timestamp"].iloc[0]).dt.total_seconds()

    for col in ("voltage_v", "raw_voltage_v", "current_signed_a", "current_mag_a",
                "power_w", "commanded_value", "commanded_limit"):
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")

    df = df.dropna(subset=["time_s", "voltage_v", "current_signed_a", "power_w"])
    df = df.sort_values("time_s").reset_index(drop=True)

    if "current_mag_a" not in df.columns:
        df["current_mag_a"] = df["current_signed_a"].abs()
    return df


# ---------------------------------------------------------------------------
# Event detection
# ---------------------------------------------------------------------------

def detect_events(df: pd.DataFrame, threshold_a: float = 0.5,
                  min_gap_s: float = 10.0, pad_s: float = 10.0,
                  min_duration_s: float = 1.0):
    """Return [(start_s, end_s, label), ...] where the load was active.

    Active = |measured current| above threshold. Short blips inside
    min_gap_s are merged into one event; windows get pad_s of context.
    """
    active_t = df.loc[df["current_mag_a"].abs() > threshold_a, "time_s"].to_numpy()
    if len(active_t) == 0:
        return []

    spans = []
    start = prev = active_t[0]
    for t in active_t[1:]:
        if t - prev > min_gap_s:
            spans.append((start, prev))
            start = t
        prev = t
    spans.append((start, prev))

    events = []
    for s, e in spans:
        if e - s < min_duration_s:
            continue
        events.append((max(0.0, s - pad_s), e + pad_s,
                       f"Event: {s:.0f}-{e:.0f} s"))
    return events


def active_samples(df: pd.DataFrame) -> pd.DataFrame:
    """Rows where the bridge actually drew current (mode not idle)."""
    mask = df["mode"].astype(str).str.lower() != "idle"
    sub = df[mask]
    if "output_on" in sub.columns:
        on = sub["output_on"].astype(str).str.lower().isin(["true", "1", "1.0"])
        sub = sub[on]
    return sub


# ---------------------------------------------------------------------------
# Plots
# ---------------------------------------------------------------------------

def _tripple_axes(df, events, title, out_path, ylabel_extra=""):
    fig, axes = plt.subplots(3, 1, figsize=(12, 9), sharex=True)
    series = [("voltage_v", "Voltage [V]", COLORS["v"]),
              ("current_signed_a", "Current [A]", COLORS["i"]),
              ("power_w", "Power [W]", COLORS["p"])]
    for ax, (col, ylab, color) in zip(axes, series):
        ax.plot(df["time_s"], df[col], color=color, lw=0.8)
        ax.set_ylabel(ylab + ylabel_extra)
        ax.grid(True, alpha=0.4)
        for s, e, label in events:
            ax.axvspan(s, e, color="tab:red", alpha=0.08)
    axes[0].set_title(title)
    axes[-1].set_xlabel("Elapsed time [s]")
    fig.tight_layout()
    fig.savefig(out_path, dpi=300, bbox_inches="tight")
    plt.close(fig)


def plot_overview(df, events, out_path):
    name = out_path.stem.replace("_overview", "")
    _tripple_axes(df, events, f"{name} - session overview", out_path)


def plot_event_zoom(df, window, label, out_path):
    s, e, _ = window
    sub = df[(df["time_s"] >= s) & (df["time_s"] <= e)]
    if sub.empty:
        print(f"  (skip empty window {s:.0f}-{e:.0f} s)", file=sys.stderr)
        return
    fig, axes = plt.subplots(3, 1, figsize=(12, 9), sharex=True)

    axes[0].plot(sub["time_s"], sub["voltage_v"], color=COLORS["v"], lw=1.2)
    axes[0].set_ylabel("Voltage [V]")

    # Staircase style: setpoints are held, so steps-post reflects the real
    # behaviour much better than a connected line. Commanded value overlaid.
    axes[1].plot(sub["time_s"], sub["current_signed_a"],
                 color=COLORS["i"], lw=1.2, drawstyle="steps-post")
    if "commanded_value" in sub.columns:
        cmd = sub["commanded_value"]
        cmd_mask = sub["current_mag_a"] > 0.01
        axes[1].plot(sub.loc[cmd_mask, "time_s"], -cmd[cmd_mask],
                     color="grey", ls="--", lw=0.8, label="commanded (sink sign)")
        axes[1].legend(loc="lower left", fontsize=8)
    axes[1].set_ylabel("Current [A]")

    axes[2].plot(sub["time_s"], sub["power_w"],
                 color=COLORS["p"], lw=1.2, drawstyle="steps-post")
    axes[2].set_ylabel("Power [W]")
    axes[2].set_xlabel("Elapsed time [s]")

    for ax in axes:
        ax.grid(True, alpha=0.4)
    axes[0].set_title(label)
    fig.tight_layout()
    fig.savefig(out_path, dpi=300, bbox_inches="tight")
    plt.close(fig)


def plot_polarization(df, events, out_png, out_csv):
    act = active_samples(df)
    if act.empty:
        print("  (no active samples - polarization plot skipped)", file=sys.stderr)
        return
    fig, ax = plt.subplots(figsize=(10, 7))
    ax.scatter(act["current_signed_a"], act["voltage_v"], s=8, alpha=0.4,
               color="tab:blue", label="20 Hz samples")

    # Plateau means: average V/I/P per commanded setpoint. This is the
    # actual polarization curve, robust against the ramp transitions.
    if "commanded_value" in act.columns:
        # Steady-state filter: keep only samples whose measured current is
        # within 10% of the commanded value. This excludes the exponential
        # ramp transitions after every setpoint change and keeps the
        # plateau means representative of the actual hold.
        cmd = act["commanded_value"].abs()
        meas = act["current_mag_a"]
        act = act[(meas >= 0.9 * cmd) & (meas <= 1.1 * cmd) & (cmd > 0)]
        stats = (act.groupby(act["commanded_value"].round(2))
                    .agg(mean_v=("voltage_v", "mean"),
                         mean_i=("current_signed_a", "mean"),
                         mean_p=("power_w", "mean"),
                         n=("voltage_v", "size"))
                    .reset_index()
                    .sort_values("mean_i"))
        stats.to_csv(out_csv, index=False,
                     float_format="%.4f")
        ax.plot(stats["mean_i"], stats["mean_v"], "-o", color="tab:red",
                lw=1.5, ms=6, label="plateau mean per setpoint")
        for _, row in stats.iterrows():
            ax.annotate(f"{row['mean_v']:.2f} V @ {abs(row['mean_i']):.0f} A",
                        (row["mean_i"], row["mean_v"]),
                        textcoords="offset points", xytext=(8, 5), fontsize=8)
    ax.set_xlabel("Current [A] (negative = sink)")
    ax.set_ylabel("Voltage [V]")
    ax.set_title("Polarization curve (active samples only)")
    ax.grid(True, alpha=0.4)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_png, dpi=300, bbox_inches="tight")
    plt.close(fig)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Analyze Regatron fast-log CSVs.")
    ap.add_argument("inputs", nargs="+", help="fastlog CSV file(s)")
    ap.add_argument("--threshold-a", type=float, default=0.5,
                    help="current threshold [A] that counts as 'load active'")
    ap.add_argument("--min-gap-s", type=float, default=10.0,
                    help="gaps shorter than this merge into one event")
    ap.add_argument("--pad-s", type=float, default=10.0,
                    help="context padding around each event window")
    ap.add_argument("--out", default="reports", help="output directory")
    args = ap.parse_args()

    for pattern in args.inputs:
        for csv_path in sorted(Path().glob(pattern)) if any(ch in pattern for ch in "*?[") else [Path(pattern)]:
            if not csv_path.exists():
                print(f"not found: {csv_path}", file=sys.stderr)
                continue
            df = load_fastlog(csv_path)
            events = detect_events(df, args.threshold_a, args.min_gap_s, args.pad_s)
            out_dir = Path(args.out) / csv_path.stem
            out_dir.mkdir(parents=True, exist_ok=True)

            print(f"{csv_path} -> {out_dir}/ "
                  f"({len(df)} rows, {df['time_s'].iloc[-1]:.0f} s, {len(events)} events)")

            plot_overview(df, events, out_dir / f"{csv_path.stem}_overview.png")
            for i, window in enumerate(events, 1):
                s, e, label = window
                plot_event_zoom(df, window,
                                f"Event {i}: {s:.0f}-{e:.0f} s",
                                out_dir / f"{csv_path.stem}_event{i}_zoom.png")
            plot_polarization(df, events,
                              out_dir / f"{csv_path.stem}_polarization.png",
                              out_dir / f"{csv_path.stem}_plateau_stats.csv")

    print("done.")


if __name__ == "__main__":
    main()
