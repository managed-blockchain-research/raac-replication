#!/usr/bin/env python3
"""
RAAC results parser.

Reads:
  <results_dir>/baseline_besu_N/gc_besu.log     — G1GC log
  <results_dir>/raac_besu_N/gc_besu.log
  <results_dir>/baseline_nm_N/gc_events.csv     — from NettraceGcParser --csv
  <results_dir>/raac_nm_N/gc_events.csv
  <results_dir>/**/raac_logs/worker*_raac.jsonl  — per-worker AI decisions

Outputs markdown table to stdout.
"""
import argparse
import csv
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
from statistics import mean, stdev

_PAUSE_RE = re.compile(
    r'\[gc\s+\]\s+GC\(\d+\)\s+Pause\s+(Young|Mixed|Full|Remark|Cleanup).*?(\d+\.\d+)ms\s*$'
)


def parse_besu_gc(gc_log: Path):
    full_count = 0
    total_ms = 0.0
    all_pauses = []
    if not gc_log.exists():
        return full_count, total_ms, all_pauses
    with open(gc_log) as f:
        for line in f:
            m = _PAUSE_RE.search(line)
            if m:
                pause_type, ms = m.group(1), float(m.group(2))
                all_pauses.append(ms)
                total_ms += ms
                if pause_type == 'Full':
                    full_count += 1
    return full_count, total_ms, all_pauses


def parse_nm_gc(gc_csv: Path):
    full_count = 0
    total_ms = 0.0
    all_pauses = []
    if not gc_csv.exists():
        return full_count, total_ms, all_pauses
    with open(gc_csv) as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                ms = float(row.get('pause_ms', 0))
                gen = row.get('gen', '').strip()
                all_pauses.append(ms)
                total_ms += ms
                if gen in ('2', 'Full', 'full'):
                    full_count += 1
            except ValueError:
                continue
    return full_count, total_ms, all_pauses


def parse_raac_logs(raac_log_dir: Path):
    normal_count = attack_count = tp = fp = blocked = 0
    if not raac_log_dir.exists():
        return None
    for jsonl in raac_log_dir.glob('worker*_raac.jsonl'):
        with open(jsonl) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                tx_type = rec.get('type', 'normal')
                ai_action = rec.get('ai_action', 'accept')
                if tx_type == 'attack':
                    attack_count += 1
                else:
                    normal_count += 1
                if ai_action == 'reject':
                    blocked += 1
                    if tx_type == 'attack':
                        tp += 1
                    else:
                        fp += 1
    if attack_count + normal_count == 0:
        return None
    tpr = tp / attack_count * 100 if attack_count > 0 else float('nan')
    fpr = fp / normal_count * 100 if normal_count > 0 else float('nan')
    return dict(normal=normal_count, attack=attack_count, tp=tp, fp=fp,
                blocked=blocked, tpr=tpr, fpr=fpr)


# Worker cleanup line: [MixedAttack/RAAC] Worker N: normal=X attack=Y | ... | TPR=T% FPR=F%
_WORKER_CLEANUP_RE = re.compile(
    r'\[MixedAttack/RAAC\] Worker \d+:.*?'
    r'normal=(\d+)\s+attack=(\d+).*?'
    r'allowed=(\d+)\s+blocked=(\d+).*?'
    r'TPR=([\d.]+)%\s+FPR=([\d.]+)%'
)


def parse_raac_from_caliper_log(caliper_log: Path):
    """Fallback: aggregate worker summary lines from caliper console log."""
    if not caliper_log.exists():
        return None
    normal_count = attack_count = allowed = blocked = 0
    found = False
    with open(caliper_log, errors='replace') as f:
        for line in f:
            m = _WORKER_CLEANUP_RE.search(line)
            if not m:
                continue
            found = True
            normal_count += int(m.group(1))
            attack_count += int(m.group(2))
            allowed      += int(m.group(3))
            blocked      += int(m.group(4))
    if not found or attack_count + normal_count == 0:
        return None
    # Re-derive tp/fp from blocked count and attack ratio
    expected_tp = blocked * (attack_count / (attack_count + normal_count))
    tp = round(expected_tp)
    fp = blocked - tp
    tpr = tp / attack_count * 100 if attack_count > 0 else float('nan')
    fpr = fp / normal_count * 100 if normal_count > 0 else float('nan')
    return dict(normal=normal_count, attack=attack_count, tp=tp, fp=fp,
                blocked=blocked, tpr=tpr, fpr=fpr)


def collect_runs(results_dir: Path):
    runs = defaultdict(lambda: defaultdict(list))  # runs[client][variant] = [metrics, ...]
    for run_dir in sorted(results_dir.iterdir()):
        if not run_dir.is_dir():
            continue
        name = run_dir.name
        # Expect: {variant}_{client}_{rep}
        parts = name.split('_')
        if len(parts) < 3:
            continue
        variant = parts[0]      # baseline | raac
        client = parts[1]       # besu | nm
        if variant not in ('baseline', 'raac'):
            continue
        if client == 'besu':
            full_count, total_ms, pauses = parse_besu_gc(run_dir / 'gc_besu.log')
        elif client == 'nm':
            full_count, total_ms, pauses = parse_nm_gc(run_dir / 'gc_events.csv')
        else:
            continue
        raac_stats = parse_raac_logs(run_dir / 'raac_logs')
        if raac_stats is None and variant == 'raac':
            raac_stats = parse_raac_from_caliper_log(run_dir / 'caliper_console.log')
        runs[client][variant].append(dict(
            full_gc=full_count,
            total_gc_ms=total_ms,
            pauses=pauses,
            raac=raac_stats,
        ))
    return runs


def fmt(values, unit=''):
    if not values:
        return 'N/A'
    m = mean(values)
    s = stdev(values) if len(values) > 1 else 0.0
    return f'{m:.1f}±{s:.1f}{unit}'


def fmt1(values, unit=''):
    if not values:
        return 'N/A'
    return f'{mean(values):.1f}{unit}'


def print_table(runs, results_dir: Path):
    print('# RAAC Evaluation — Results Summary\n')
    print(f'Results directory: `{results_dir}`\n')

    for client in ('besu', 'nm'):
        if client not in runs:
            continue
        client_label = 'Besu (JVM G1GC, 1 GB)' if client == 'besu' else 'Nethermind (.NET GC, 1 GB)'
        print(f'## Client: {client_label}\n')
        print('| Variant | N | Full GC (mean±σ) | Total GC ms (mean±σ) | p50 Pause (ms) | p95 Pause (ms) | TPR % | FPR % |')
        print('|---------|---|-----------------|---------------------|----------------|----------------|-------|-------|')
        for variant in ('baseline', 'raac'):
            reps = runs[client].get(variant, [])
            n = len(reps)
            full_gcs = [r['full_gc'] for r in reps]
            total_ms_list = [r['total_gc_ms'] for r in reps]
            all_pauses = [p for r in reps for p in r['pauses']]
            all_pauses_sorted = sorted(all_pauses)
            p50 = all_pauses_sorted[int(len(all_pauses_sorted) * 0.50)] if all_pauses_sorted else float('nan')
            p95 = all_pauses_sorted[int(len(all_pauses_sorted) * 0.95)] if all_pauses_sorted else float('nan')

            # RAAC stats (only meaningful for raac variant)
            tpr_vals = [r['raac']['tpr'] for r in reps if r['raac'] is not None]
            fpr_vals = [r['raac']['fpr'] for r in reps if r['raac'] is not None]
            tpr_str = fmt1(tpr_vals, '%') if tpr_vals else 'N/A'
            fpr_str = fmt1(fpr_vals, '%') if fpr_vals else 'N/A'

            print(f'| {variant:8s} | {n} | {fmt(full_gcs):15s} | {fmt(total_ms_list, "ms"):19s} | '
                  f'{p50:14.1f} | {p95:14.1f} | {tpr_str:5s} | {fpr_str:5s} |')
        print()

    # Reduction table
    print('## GC Reduction: RAAC vs Baseline\n')
    print('| Client | Metric | Baseline (mean) | RAAC (mean) | Reduction % |')
    print('|--------|--------|-----------------|-------------|-------------|')
    for client in ('besu', 'nm'):
        if client not in runs:
            continue
        base = runs[client].get('baseline', [])
        raac = runs[client].get('raac', [])
        if not base or not raac:
            continue
        for metric, label in [('full_gc', 'Full GC count'), ('total_gc_ms', 'Total GC ms')]:
            b_vals = [r[metric] for r in base]
            r_vals = [r[metric] for r in raac]
            b_mean = mean(b_vals) if b_vals else 0
            r_mean = mean(r_vals) if r_vals else 0
            reduction = (b_mean - r_mean) / b_mean * 100 if b_mean > 0 else float('nan')
            print(f'| {client:6s} | {label:16s} | {b_mean:15.1f} | {r_mean:11.1f} | {reduction:11.1f}% |')
    print()

    # RAAC classification summary
    print('## RAAC AI Classification Summary (raac variant only)\n')
    print('| Client | Rep | Normal | Attack | TP (blocked attack) | FP (blocked normal) | TPR % | FPR % |')
    print('|--------|-----|--------|--------|---------------------|---------------------|-------|-------|')
    for client in ('besu', 'nm'):
        if client not in runs:
            continue
        for i, rep in enumerate(runs[client].get('raac', []), 1):
            r = rep['raac']
            if r is None:
                print(f'| {client} | {i} | N/A | N/A | N/A | N/A | N/A | N/A |')
            else:
                print(f'| {client} | {i} | {r["normal"]} | {r["attack"]} | {r["tp"]} | {r["fp"]} | '
                      f'{r["tpr"]:.1f}% | {r["fpr"]:.1f}% |')
    print()


def export_gc_csv(runs, out_path: Path):
    rows = []
    for client, variants in runs.items():
        for variant, reps in variants.items():
            for rep_idx, rep in enumerate(reps, 1):
                for pause_ms in rep['pauses']:
                    rows.append(dict(variant=variant, client=client, rep=rep_idx, pause_ms=pause_ms))
    with open(out_path, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=['variant', 'client', 'rep', 'pause_ms'])
        w.writeheader()
        w.writerows(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--results-dir', required=True)
    ap.add_argument('--out-csv', default=None)
    args = ap.parse_args()

    results_dir = Path(args.results_dir)
    runs = collect_runs(results_dir)
    print_table(runs, results_dir)

    if args.out_csv:
        export_gc_csv(runs, Path(args.out_csv))
        print(f'Per-event GC CSV: {args.out_csv}', file=sys.stderr)


if __name__ == '__main__':
    main()
