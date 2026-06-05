#!/usr/bin/env python3
"""
Statistical analysis for 5x ctrl vs 5x lass75 validation.
Generates final_evaluation_report.md with mean/stdev comparison.
"""

import re
import sys
import os
import json
import statistics
from pathlib import Path


def parse_gc_log(gc_log_path):
    """Parse G1 GC log, return dict with gc_count, max_pause_ms, total_pause_ms, pauses list."""
    pauses = []
    try:
        with open(gc_log_path, 'r') as f:
            for line in f:
                m = re.search(
                    r'GC\(\d+\)\s+Pause\s+\w+.*?\d+M->\d+M\(\d+M\)\s+([\d.]+)ms',
                    line
                )
                if m:
                    pauses.append(float(m.group(1)))
    except FileNotFoundError:
        pass
    if not pauses:
        return {'gc_count': 0, 'max_pause_ms': 0.0, 'total_pause_ms': 0.0,
                'avg_pause_ms': 0.0, 'p99_pause_ms': 0.0, 'pauses': []}
    pauses_sorted = sorted(pauses)
    p99_idx = int(len(pauses_sorted) * 0.99)
    return {
        'gc_count': len(pauses),
        'max_pause_ms': max(pauses),
        'total_pause_ms': sum(pauses),
        'avg_pause_ms': statistics.mean(pauses),
        'p99_pause_ms': pauses_sorted[p99_idx],
        'pauses': pauses,
    }


def parse_test_log(test_log_path):
    """Parse extreme_baseline_test.py output, return dict with tps, p99, max_lat."""
    result = {'tps': None, 'p99_ms': None, 'max_ms': None,
              'mean_ms': None, 'stdev_ms': None, 'success_count': None}
    try:
        with open(test_log_path, 'r') as f:
            lines = f.readlines()
        for line in lines:
            m = re.search(r'Total Rate:\s+([\d.]+)\s+tx/s', line)
            if m:
                result['tps'] = float(m.group(1))
            m = re.search(r'^\s+P99:\s+([\d.]+)', line)
            if m:
                result['p99_ms'] = float(m.group(1))
            m = re.search(r'^\s+Max:\s+([\d.]+)', line)
            if m:
                result['max_ms'] = float(m.group(1))
            m = re.search(r'^\s+Mean:\s+([\d.]+)', line)
            if m:
                result['mean_ms'] = float(m.group(1))
            m = re.search(r'^\s+StdDev:\s+([\d.]+)', line)
            if m:
                result['stdev_ms'] = float(m.group(1))
            m = re.search(r'Successful TXs:\s+(\d+)', line)
            if m:
                result['success_count'] = int(m.group(1))
    except FileNotFoundError:
        pass
    return result


def parse_lass_events(besu_console_path):
    """Parse LASS activation/spill metrics from E-SPILL TRAJECTORY lines."""
    activations = 0
    spill_events = 0
    total_spilled = 0
    peak_heap_pct = 0.0
    # Track the final (highest) cumulative values from TRAJECTORY lines
    max_activations = 0
    max_spill_events = 0
    max_total_spilled = 0
    try:
        with open(besu_console_path, 'r') as f:
            for line in f:
                if 'E-SPILL TRAJECTORY' not in line and 'E-SPILL STATS' not in line:
                    continue
                # Parse: heap=X% ... activations=N spillEvents=N totalSpilled=N
                m_heap = re.search(r'heap=([\d.]+)%', line)
                if m_heap:
                    peak_heap_pct = max(peak_heap_pct, float(m_heap.group(1)))
                m_act = re.search(r'activations=(\d+)', line)
                if m_act:
                    max_activations = max(max_activations, int(m_act.group(1)))
                m_spill = re.search(r'spillEvents=(\d+)', line)
                if m_spill:
                    max_spill_events = max(max_spill_events, int(m_spill.group(1)))
                m_total = re.search(r'totalSpilled=(\d+)', line)
                if m_total:
                    max_total_spilled = max(max_total_spilled, int(m_total.group(1)))
    except FileNotFoundError:
        pass
    return {
        'activations': max_activations,
        'spill_events': max_spill_events,
        'total_spilled': max_total_spilled,
        'peak_heap_pct': peak_heap_pct,
    }


def collect_runs(results_dir, variant, n):
    """Collect metrics from all n runs of a variant."""
    runs = []
    for i in range(1, n + 1):
        label = f"{variant}_{i}"
        run_dir = results_dir / label
        gc = parse_gc_log(run_dir / 'gc.log')
        test = parse_test_log(run_dir / 'test.log')
        lass = parse_lass_events(run_dir / 'besu_console.log')
        runs.append({'label': label, 'gc': gc, 'test': test, 'lass': lass})
        print(f"  {label}: TPS={test['tps']} P99={test['p99_ms']}ms MaxGC={gc['max_pause_ms']}ms GCcount={gc['gc_count']}")
    return runs


def stat(values):
    """Return (mean, stdev, min, max) for a list, handling missing values."""
    v = [x for x in values if x is not None]
    if not v:
        return (None, None, None, None)
    mean = statistics.mean(v)
    stdev = statistics.stdev(v) if len(v) > 1 else 0.0
    return (mean, stdev, min(v), max(v))


def pct_change(ctrl_mean, lass_mean):
    if ctrl_mean is None or ctrl_mean == 0:
        return None
    return (lass_mean - ctrl_mean) / ctrl_mean * 100.0


def fmt(val, decimals=2):
    if val is None:
        return 'N/A'
    return f"{val:.{decimals}f}"


def generate_report(results_dir, ctrl_runs, lass_runs):
    ctrl_tps = [r['test']['tps'] for r in ctrl_runs]
    lass_tps = [r['test']['tps'] for r in lass_runs]
    ctrl_p99 = [r['test']['p99_ms'] for r in ctrl_runs]
    lass_p99 = [r['test']['p99_ms'] for r in lass_runs]
    ctrl_maxgc = [r['gc']['max_pause_ms'] for r in ctrl_runs]
    lass_maxgc = [r['gc']['max_pause_ms'] for r in lass_runs]
    ctrl_gccount = [r['gc']['gc_count'] for r in ctrl_runs]
    lass_gccount = [r['gc']['gc_count'] for r in lass_runs]
    ctrl_totalgc = [r['gc']['total_pause_ms'] for r in ctrl_runs]
    lass_totalgc = [r['gc']['total_pause_ms'] for r in lass_runs]

    cm_tps, cs_tps, cmn_tps, cmx_tps = stat(ctrl_tps)
    lm_tps, ls_tps, lmn_tps, lmx_tps = stat(lass_tps)
    cm_p99, cs_p99, _, _ = stat(ctrl_p99)
    lm_p99, ls_p99, _, _ = stat(lass_p99)
    cm_maxgc, cs_maxgc, _, _ = stat(ctrl_maxgc)
    lm_maxgc, ls_maxgc, _, _ = stat(lass_maxgc)
    cm_gccount, cs_gccount, _, _ = stat(ctrl_gccount)
    lm_gccount, ls_gccount, _, _ = stat(lass_gccount)
    cm_totalgc, cs_totalgc, _, _ = stat(ctrl_totalgc)
    lm_totalgc, ls_totalgc, _, _ = stat(lass_totalgc)

    lass_activations = [r['lass']['activations'] for r in lass_runs]
    lm_act, _, _, _ = stat(lass_activations)

    # Per-run table rows
    def run_row(run):
        t = run['test']
        g = run['gc']
        return (
            run['label'],
            fmt(t['tps'], 1),
            fmt(t['p99_ms'], 1),
            fmt(g['max_pause_ms'], 1),
            str(g['gc_count']),
            fmt(g['total_pause_ms'], 1),
            str(run['lass']['activations']),
        )

    ctrl_rows = [run_row(r) for r in ctrl_runs]
    lass_rows = [run_row(r) for r in lass_runs]

    delta_tps = pct_change(cm_tps, lm_tps)
    delta_p99 = pct_change(cm_p99, lm_p99)
    delta_maxgc = pct_change(cm_maxgc, lm_maxgc)
    delta_gccount = pct_change(cm_gccount, lm_gccount)
    delta_totalgc = pct_change(cm_totalgc, lm_totalgc)

    def arrow(delta, lower_is_better=True):
        if delta is None:
            return ''
        if lower_is_better:
            return f"{'↓' if delta < 0 else '↑'} {abs(delta):.1f}%"
        else:
            return f"{'↑' if delta > 0 else '↓'} {abs(delta):.1f}%"

    lines = []
    lines.append("# Final Evaluation Report: LASS-75 vs Ctrl")
    lines.append("")
    lines.append(f"**Generated:** {__import__('datetime').datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"**Results dir:** `{results_dir}`")
    lines.append("")
    lines.append("## Configuration")
    lines.append("")
    lines.append("| Parameter | Value |")
    lines.append("|-----------|-------|")
    lines.append("| JVM Heap | 4g (Xms4g Xmx4g) |")
    lines.append("| GC | G1GC MaxGCPauseMillis=200 |")
    lines.append("| Eden sizing | G1MaxNewSizePercent=90 G1NewSizePercent=20 |")
    lines.append("| Workers | 20 |")
    lines.append("| Warmup | 120s (discarded) |")
    lines.append("| Measurement | 300s |")
    lines.append("| Slots/tx | 200 |")
    lines.append("| LASS threshold | 0.75 (deactivate=0.60, consecutive_samples=1) |")
    lines.append("| Replications | 5 per variant |")
    lines.append("")
    lines.append("## Per-Run Data")
    lines.append("")
    lines.append("### ctrl (stock Besu 24.1.1)")
    lines.append("")
    lines.append("| Run | TPS | P99 (ms) | MaxGC (ms) | GC count | Total GC (ms) | LASS activations |")
    lines.append("|-----|-----|----------|------------|----------|----------------|------------------|")
    for row in ctrl_rows:
        lines.append(f"| {row[0]} | {row[1]} | {row[2]} | {row[3]} | {row[4]} | {row[5]} | {row[6]} |")
    lines.append("")
    lines.append("### lass75 (LASS-75)")
    lines.append("")
    lines.append("| Run | TPS | P99 (ms) | MaxGC (ms) | GC count | Total GC (ms) | LASS activations |")
    lines.append("|-----|-----|----------|------------|----------|----------------|------------------|")
    for row in lass_rows:
        lines.append(f"| {row[0]} | {row[1]} | {row[2]} | {row[3]} | {row[4]} | {row[5]} | {row[6]} |")
    lines.append("")
    lines.append("## Summary Statistics (mean ± stdev)")
    lines.append("")
    lines.append("| Metric | ctrl | lass75 | Change |")
    lines.append("|--------|------|--------|--------|")
    lines.append(f"| TPS | {fmt(cm_tps,1)} ± {fmt(cs_tps,1)} | {fmt(lm_tps,1)} ± {fmt(ls_tps,1)} | {arrow(delta_tps, lower_is_better=False)} |")
    lines.append(f"| P99 Latency (ms) | {fmt(cm_p99,1)} ± {fmt(cs_p99,1)} | {fmt(lm_p99,1)} ± {fmt(ls_p99,1)} | {arrow(delta_p99)} |")
    lines.append(f"| Max GC Pause (ms) | {fmt(cm_maxgc,1)} ± {fmt(cs_maxgc,1)} | {fmt(lm_maxgc,1)} ± {fmt(ls_maxgc,1)} | {arrow(delta_maxgc)} |")
    lines.append(f"| GC Event Count | {fmt(cm_gccount,1)} ± {fmt(cs_gccount,1)} | {fmt(lm_gccount,1)} ± {fmt(ls_gccount,1)} | {arrow(delta_gccount)} |")
    lines.append(f"| Total GC Time (ms) | {fmt(cm_totalgc,1)} ± {fmt(cs_totalgc,1)} | {fmt(lm_totalgc,1)} ± {fmt(ls_totalgc,1)} | {arrow(delta_totalgc)} |")
    lines.append(f"| LASS activations | 0 | {fmt(lm_act,1)} ± — | — |")
    lines.append("")
    lines.append("## Interpretation")
    lines.append("")

    # Determine whether LASS shows benefit
    gc_reduction = None
    if delta_totalgc is not None:
        gc_reduction = -delta_totalgc  # positive = reduction
    tps_delta = delta_tps

    if gc_reduction is not None and gc_reduction > 5:
        lines.append(f"LASS-75 reduced total GC time by **{gc_reduction:.1f}%** "
                     f"(ctrl: {fmt(cm_totalgc,1)}ms → lass75: {fmt(lm_totalgc,1)}ms).")
    elif delta_maxgc is not None and -delta_maxgc > 5:
        lines.append(f"LASS-75 reduced max GC pause by **{-delta_maxgc:.1f}%** "
                     f"(ctrl: {fmt(cm_maxgc,1)}ms → lass75: {fmt(lm_maxgc,1)}ms).")
    else:
        lines.append(f"GC differences are small (max pause ctrl={fmt(cm_maxgc,1)}ms vs lass75={fmt(lm_maxgc,1)}ms). "
                     f"This may indicate the heap size (4g) was sufficient and LASS-75 had limited effect at this workload intensity.")

    if tps_delta is not None:
        sign = "higher" if tps_delta > 0 else "lower"
        lines.append(f"Throughput was {abs(tps_delta):.1f}% {sign} under LASS-75 "
                     f"(ctrl: {fmt(cm_tps,1)} TPS → lass75: {fmt(lm_tps,1)} TPS).")
    lines.append("")
    lines.append("### LASS Activation Check")
    lines.append("")
    if lm_act and lm_act > 0:
        lines.append(f"LASS-75 activated on average {fmt(lm_act,1)} times per run, confirming the threshold was reached.")
    else:
        lines.append("LASS-75 showed 0 activations. The heap may not have reached 75% "
                     "threshold — consider using a smaller heap or increasing workload intensity.")
    lines.append("")
    lines.append("---")
    lines.append("*Report generated by analyze_5x_validation.py*")

    report_text = "\n".join(lines)
    report_path = results_dir / "final_evaluation_report.md"
    with open(report_path, 'w') as f:
        f.write(report_text)
    print(f"\nReport written: {report_path}")
    return report_path


def main():
    if len(sys.argv) < 2:
        print("Usage: analyze_5x_validation.py <results_dir>")
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    n = 5

    print(f"Analyzing results in: {results_dir}")
    print("")
    print("ctrl runs:")
    ctrl_runs = collect_runs(results_dir, 'ctrl', n)
    print("")
    print("lass75 runs:")
    lass_runs = collect_runs(results_dir, 'lass75', n)

    # Save raw JSON
    raw = {
        'ctrl': [{'label': r['label'], 'test': r['test'], 'gc': {k: v for k, v in r['gc'].items() if k != 'pauses'}, 'lass': r['lass']} for r in ctrl_runs],
        'lass75': [{'label': r['label'], 'test': r['test'], 'gc': {k: v for k, v in r['gc'].items() if k != 'pauses'}, 'lass': r['lass']} for r in lass_runs],
    }
    with open(results_dir / 'raw_metrics.json', 'w') as f:
        json.dump(raw, f, indent=2)

    generate_report(results_dir, ctrl_runs, lass_runs)


if __name__ == '__main__':
    main()
