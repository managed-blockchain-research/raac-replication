#!/usr/bin/env python3
"""
Generate the final RAAC paper figures from the n=8 bootstrap_ci_report.json
for NM and Besu (redesigned admission-control mechanism, corrected Besu
networkconfig, TxPool.Size=2048 pool-bound arms). No titles (per figure) --
captions carry the framing in the LaTeX. Output: PDF (vector, for LaTeX
\\includegraphics) + PNG (quick preview).
"""
import json
import sys
from pathlib import Path

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError:
    print('ERROR: matplotlib/numpy required', file=sys.stderr)
    sys.exit(1)

NM_JSON = Path('/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260802_004133_raac_nm_full6arm/bootstrap_ci_report.json')
BESU_JSON = Path('/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260801_131949_raac_full6arm/bootstrap_ci_report.json')
OUT_DIR = Path('/home/yeochan.yoon/banning/papers/raac')

ARM_ORDER = ['static', 'native_evict', 'dagor', 'heap_only', 'moderate', 'aggressive']
ARM_LABELS = ['Static', 'Native\nEvict', 'Dagor', 'Heap\nOnly', 'Moderate', 'Aggressive']
COLORS = ['#7f7f7f', '#1f77b4', '#9467bd', '#2ca02c', '#ff7f0e', '#d62728']

# ETRI Journal author checklist: in-figure text must be 6-8pt, consistent
# throughout, in Times New Roman. Times New Roman itself isn't installed on
# this Linux host; Liberation Serif is a metrically-compatible substitute
# (falls back to Nimbus Roman/DejaVu Serif if unavailable in some renderer).
plt.rcParams.update({
    'font.family': 'serif',
    'font.serif': ['Times New Roman', 'Liberation Serif', 'Nimbus Roman', 'DejaVu Serif'],
    'font.size': 11,
    'axes.labelsize': 12,
    'xtick.labelsize': 10,
    'ytick.labelsize': 10,
    'legend.fontsize': 10,
    'axes.spines.top': False,
    'axes.spines.right': False,
    'pdf.fonttype': 42,
    'ps.fonttype': 42,
})


def load(json_path, suffix):
    data = json.load(open(json_path))
    out = {}
    for arm in ARM_ORDER:
        key = f'{arm}_{suffix}'
        if key in data:
            out[arm] = data[key]
    return out


def plot_platform(data, platform_label, out_stem):
    """Single-panel figure: GC duty cycle with 95% CI across admission
    policies. Round-completion rate and rounds-survived are 100%/5.00 for
    every policy on both platforms (no variance to plot) and are already
    reported in the accompanying table, so they are omitted here rather
    than devoting half the figure to a flat, zero-information panel. No
    panel title -- caption in the LaTeX source carries the framing."""
    arms = [a for a in ARM_ORDER if a in data]
    labels = [ARM_LABELS[ARM_ORDER.index(a)] for a in arms]
    colors = [COLORS[ARM_ORDER.index(a)] for a in arms]
    x = np.arange(len(arms))

    fig, ax = plt.subplots(1, 1, figsize=(5.2, 3.4))

    duty_mean = [data[a]['duty_cycle_mean'] * 1000 for a in arms]  # scale to per-mille for readability
    duty_lo = [data[a]['duty_cycle_ci95_lo'] * 1000 for a in arms]
    duty_hi = [data[a]['duty_cycle_ci95_hi'] * 1000 for a in arms]
    yerr_lo = [m - lo for m, lo in zip(duty_mean, duty_lo)]
    yerr_hi = [hi - m for m, hi in zip(duty_mean, duty_hi)]

    ax.bar(x, duty_mean, yerr=[yerr_lo, yerr_hi], color=colors, alpha=0.85,
           width=0.6, capsize=3, error_kw={'linewidth': 1})
    ax.set_ylabel('GC duty cycle (‰ of wall-clock)')
    ax.set_xticks(x)
    ax.set_xticklabels(labels)

    fig.tight_layout(pad=1.2)
    for ext in ('pdf', 'svg', 'png'):
        # 300dpi minimum per ETRI Journal figure-resolution requirement.
        fig.savefig(OUT_DIR / f'{out_stem}.{ext}', dpi=300, bbox_inches='tight')
    plt.close(fig)
    print(f'wrote {out_stem}.pdf / .svg / .png')


HEAP1G_JSON = Path('/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260803_081804_raac_besu1g_6arm/bootstrap_ci_report.json')
HEAP8G_JSON = Path('/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260804_070042_raac_besu8g_6arm/bootstrap_ci_report.json')

# Calm-round (attackRatio=0) benign-transaction fail counts, computed directly
# from each run's caliper_console.log (see analysis session 2026-08-05) --
# not part of bootstrap_ci_report.json, hand-computed once and hardcoded here
# since recomputing requires grepping raw per-run logs across 3 result dirs.
COLLATERAL_FAIL_PCT = {
    '1GB': {'native_evict': 2863 / 33977 * 100, 'others_max': 0.0},
    '4GB': {'native_evict': 1987 / 21406 * 100, 'others_max': 23 / 199976 * 100},
    '8GB': {'native_evict': 3343 / 39382 * 100, 'others_max': 114 / 191889 * 100},
}


def plot_heap_doseresponse():
    """Two-panel figure: (left) GC duty cycle vs. heap size, one line per
    policy, showing RAAC's own mechanisms' effect shrinking from 1GB to 8GB
    while Native Evict stays low throughout; (right) Native Evict's
    calm-round (benign-traffic) collateral fail rate vs. heap size, with all
    other policies annotated as ~0% throughout. No panel titles -- caption
    in LaTeX carries the framing."""
    heaps = ['1GB', '4GB', '8GB']
    heap_x = [1, 4, 8]
    sources = {'1GB': HEAP1G_JSON, '4GB': BESU_JSON, '8GB': HEAP8G_JSON}
    per_heap = {h: load(sources[h], 'besu') for h in heaps}

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(9.6, 3.4))

    for i, arm in enumerate(ARM_ORDER):
        means = [per_heap[h][arm]['duty_cycle_mean'] * 1000 for h in heaps]
        los = [per_heap[h][arm]['duty_cycle_ci95_lo'] * 1000 for h in heaps]
        his = [per_heap[h][arm]['duty_cycle_ci95_hi'] * 1000 for h in heaps]
        yerr = [[m - lo for m, lo in zip(means, los)], [hi - m for m, hi in zip(means, his)]]
        ax1.errorbar(heap_x, means, yerr=yerr, fmt='o-', color=COLORS[i],
                     label=ARM_LABELS[i].replace('\n', ' '), markersize=5,
                     capsize=3, linewidth=1.4)
    ax1.set_xscale('log', base=2)
    ax1.set_xticks(heap_x)
    ax1.set_xticklabels(['1 GB', '4 GB', '8 GB'])
    ax1.set_xlabel('Heap size')
    ax1.set_ylabel('GC duty cycle (‰ of wall-clock)')
    ax1.legend(loc='upper right', frameon=False, fontsize=8, ncol=1)

    ne_fail = [COLLATERAL_FAIL_PCT[h]['native_evict'] for h in heaps]
    others_fail = [COLLATERAL_FAIL_PCT[h]['others_max'] for h in heaps]
    xw = np.arange(len(heaps))
    width = 0.35
    bars_ne = ax2.bar(xw - width / 2, ne_fail, width, color=COLORS[ARM_ORDER.index('native_evict')],
                       alpha=0.85, label='Native Evict')
    bars_others = ax2.bar(xw + width / 2, others_fail, width, color='#bbbbbb',
                           alpha=0.85, label='All other policies (max)')
    ax2.set_xticks(xw)
    ax2.set_xticklabels(['1 GB', '4 GB', '8 GB'])
    ax2.set_xlabel('Heap size')
    ax2.set_ylabel('Calm-round benign-tx fail rate (%)')
    ax2.set_ylim(0, max(ne_fail) * 1.18)
    ax2.legend(loc='upper right', frameon=False, fontsize=8)

    # The "all other policies" bars are near-zero (0.00-0.06%) next to
    # Native Evict's 8-9% -- at this scale they're visually indistinguishable
    # from "no bar at all". Label every bar with its exact value so the
    # near-zero result reads as a measured near-zero, not missing data.
    ax2.bar_label(bars_ne, fmt='%.1f%%', fontsize=7, padding=2)
    ax2.bar_label(bars_others, fmt='%.2f%%', fontsize=7, padding=2)

    fig.tight_layout(pad=1.2, w_pad=3.5)
    out_stem = 'raac_fig8_heap_doseresponse'
    for ext in ('pdf', 'svg', 'png'):
        fig.savefig(OUT_DIR / f'{out_stem}.{ext}', dpi=300, bbox_inches='tight')
    plt.close(fig)
    print(f'wrote {out_stem}.pdf / .svg / .png')


SCALEDATTACK_JSON = Path('/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260805_085550_raac_besu8g_scaledattack_5arm/bootstrap_ci_report.json')
# native_evict excluded from the scaled-attack sweep (see
# run_raac_besu_8g_scaledattack_5arm.sh header) -- its tiny tx-pool bound
# doesn't survive 8x submission volume without a confounding re-tune, so
# it's absent from both the source data and this comparison.
SCALEDATTACK_ARMS = ['static', 'heap_only', 'dagor', 'moderate', 'aggressive']


def plot_scaledattack_validation():
    """Single-panel grouped-bar figure: GC duty cycle at 8GB with the
    default (1x) attack intensity vs. the same heap with attack intensity
    scaled 8x to restore the ~115% severity-to-heap ratio originally seen at
    1GB. Tests whether RAAC's own mechanisms recover a benefit once relative
    severity, not just absolute heap size, is matched. No panel title --
    caption in LaTeX carries the framing."""
    default_data = load(HEAP8G_JSON, 'besu')
    scaled_data = load(SCALEDATTACK_JSON, 'besu')

    arms = [a for a in SCALEDATTACK_ARMS if a in default_data and a in scaled_data]
    labels = [ARM_LABELS[ARM_ORDER.index(a)].replace('\n', ' ') for a in arms]
    colors = [COLORS[ARM_ORDER.index(a)] for a in arms]
    x = np.arange(len(arms))
    width = 0.35

    fig, ax = plt.subplots(1, 1, figsize=(6.0, 3.4))

    for offset, (data, label, alpha, hatch) in enumerate([
        (default_data, 'Default (1x) attack', 0.85, None),
        (scaled_data, 'Scaled (8x) attack', 0.85, '///'),
    ]):
        means = [data[a]['duty_cycle_mean'] * 1000 for a in arms]
        los = [data[a]['duty_cycle_ci95_lo'] * 1000 for a in arms]
        his = [data[a]['duty_cycle_ci95_hi'] * 1000 for a in arms]
        yerr = [[m - lo for m, lo in zip(means, los)], [hi - m for m, hi in zip(means, his)]]
        xpos = x + (offset - 0.5) * width
        ax.bar(xpos, means, width, yerr=yerr, color=colors, alpha=alpha, hatch=hatch,
               capsize=3, error_kw={'linewidth': 1}, edgecolor='black', linewidth=0.5,
               label=label)

    # Legend entries need to be intensity (not per-policy color), so build
    # a custom two-entry legend for the hatch pattern instead of the
    # per-bar color-keyed one matplotlib would otherwise produce.
    from matplotlib.patches import Patch
    legend_handles = [
        Patch(facecolor='white', edgecolor='black', linewidth=0.5, label='Default (1x) attack'),
        Patch(facecolor='white', edgecolor='black', linewidth=0.5, hatch='///', label='Scaled (8x) attack'),
    ]
    ax.legend(handles=legend_handles, loc='upper right', frameon=False, fontsize=8)

    ax.set_ylabel('GC duty cycle (‰ of wall-clock)')
    ax.set_xticks(x)
    ax.set_xticklabels(labels)

    fig.tight_layout(pad=1.2)
    out_stem = 'raac_fig9_scaledattack_validation'
    for ext in ('pdf', 'svg', 'png'):
        fig.savefig(OUT_DIR / f'{out_stem}.{ext}', dpi=300, bbox_inches='tight')
    plt.close(fig)
    print(f'wrote {out_stem}.pdf / .svg / .png')


FRAGMENTATION_JSON = Path(
    '/home/yeochan.yoon/caliper-stress-test/paper_data/'
    'fragmentation_evasion/fragmentation_fast.json'
)
ATTACK_SCORE_REF = 0.80


def plot_fragmentation_evasion():
    """Single-panel figure: per-fragment anomaly score vs. fragment payload
    size (log-x), swept over fragment counts k=1..96 of a fixed 96KB attack
    payload. Score is independent of the live pressure state (only the
    accept/reject probability given a score depends on pressure), so this
    is a clean, pressure-independent view of the mechanism the 32-fragment
    evasion threshold rests on. No panel title -- caption in LaTeX carries
    the framing."""
    data = json.load(open(FRAGMENTATION_JSON))
    k_values = data['k_values']
    bytes_per_k = [data['results'][str(k)]['fragments'][0]['bytes'] for k in k_values]
    scores = [data['results'][str(k)]['fragments'][0]['anomaly_score'] for k in k_values]

    fig, ax = plt.subplots(1, 1, figsize=(5.2, 3.4))
    ax.plot(bytes_per_k, scores, marker='o', markersize=4, color='#1f77b4', linewidth=1.2)
    ax.axhline(ATTACK_SCORE_REF, color='#d62728', linestyle='--', linewidth=1,
               label=f'Attack-score reference ({ATTACK_SCORE_REF:.2f})')
    ax.set_xscale('log')
    ax.set_xlabel('Fragment payload size (bytes)')
    ax.set_ylabel('Anomaly score')
    ax.invert_xaxis()

    for k, b, s in zip(k_values, bytes_per_k, scores):
        if k in (24, 32):
            ax.annotate(f'k={k}', (b, s), textcoords='offset points',
                        xytext=(0, 8 if k == 24 else -14), ha='center', fontsize=8)

    ax.legend(loc='lower left', frameon=False, fontsize=8)
    fig.tight_layout(pad=1.2)
    out_stem = 'raac_fig10_fragmentation_evasion'
    for ext in ('pdf', 'svg', 'png'):
        fig.savefig(OUT_DIR / f'{out_stem}.{ext}', dpi=300, bbox_inches='tight')
    plt.close(fig)
    print(f'wrote {out_stem}.pdf / .svg / .png')


def main():
    nm_completion = load(NM_JSON, 'nm')
    besu_completion = load(BESU_JSON, 'besu')
    plot_platform(nm_completion, 'Nethermind', 'raac_fig6_nm_completion_duty')
    plot_platform(besu_completion, 'Besu', 'raac_fig7_besu_completion_duty')
    plot_heap_doseresponse()
    plot_scaledattack_validation()
    plot_fragmentation_evasion()


if __name__ == '__main__':
    main()
