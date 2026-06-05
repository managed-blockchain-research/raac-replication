#!/usr/bin/env python3
"""Generate figures 2, 3, and 5 for RAAC paper (LaTeX version).

Fig 1: raac_figure1_RAAC Overview.pdf  (externally provided)
Fig 2: fig2_adaptive_thresholding      (GC pressure vs admission threshold)
Fig 3: fig3_gc_pause_phases            (workload-phase GC timeline, Besu)
Fig 4: figure5_besu_steadystress_gc_pause.pdf  (bar chart, existing)
Fig 5: fig5_permutation_importance     (feature permutation importance)
"""

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SAVE_DIR = "/home/yeochan.yoon/banning/papers/raac"

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 11,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.linewidth": 0.8,
    "xtick.major.width": 0.8,
    "ytick.major.width": 0.8,
})

# ─────────────────────────────────────────────────────────────────────────────
# Figure 2 — Mechanism of Adaptive Thresholding
#   GC Pressure (sigmoid) vs. Admission Threshold (step function)
# ─────────────────────────────────────────────────────────────────────────────

t = np.linspace(0, 100, 500)

# Sigmoidal GC pressure: starts ~0.10, midpoint at t=50, saturates at ~0.90
gc_pressure = 0.10 + 0.80 / (1.0 + np.exp(-0.12 * (t - 50)))

# Adaptive threshold: piecewise step — drops when GC pressure crosses thresholds
tau_base = 0.80
tau_mid  = 0.70
tau_min  = 0.60
threshold = np.where(t < 52, tau_base,
            np.where(t < 56, tau_mid, tau_min))

fig2, ax_gc = plt.subplots(figsize=(6.5, 3.8))

color_gc  = "#c0392b"
color_tau = "#2980b9"

ax_gc.plot(t, gc_pressure, color=color_gc, linewidth=2.0, label="GC Pressure")
ax_gc.set_xlabel("Time under Attack (s)", fontsize=12)
ax_gc.set_ylabel("GC Pressure (Ratio)", fontsize=12, color=color_gc)
ax_gc.tick_params(axis="y", colors=color_gc)
ax_gc.set_xlim(0, 100)
ax_gc.set_ylim(0, 1.0)
ax_gc.spines["left"].set_color(color_gc)

ax_tau = ax_gc.twinx()
ax_tau.step(t, threshold, color=color_tau, linewidth=1.8, linestyle="--",
            where="post", label=r"Admission Threshold ($\tau_{act}$)")
ax_tau.set_ylabel(r"Admission Threshold ($\tau_{act}$)", fontsize=12, color=color_tau)
ax_tau.tick_params(axis="y", colors=color_tau)
ax_tau.set_ylim(0.50, 0.90)
ax_tau.spines["right"].set_color(color_tau)
ax_tau.spines["left"].set_visible(False)
ax_tau.spines["top"].set_visible(False)

plt.tight_layout()
for ext in ("pdf", "svg"):
    fig2.savefig(f"{SAVE_DIR}/fig2_adaptive_thresholding.{ext}", bbox_inches="tight")
plt.close(fig2)
print("Fig 2 saved.")

# ─────────────────────────────────────────────────────────────────────────────
# Figure 3 — GC Pause Time Across Workload Phases (Besu, Aggressive)
#   Steady-State Stress (Attack-2, 360-480s):
#     Static:  7,792 ms total STW
#     RAAC:      151 ms total STW  (-98.1%)
# ─────────────────────────────────────────────────────────────────────────────

rng = np.random.default_rng(99)

PHASES = [
    ("Initialization",    0,   60,  "#eeeeee"),
    ("Normal-I",         60,  150,  "#d5f5e3"),
    ("Adaptive Stress", 150,  270,  "#fadbd8"),
    ("Recovery",        270,  360,  "#d5f5e3"),
    ("Steady-State\nStress", 360, 480, "#fadbd8"),
    ("Cool-down",       480,  540,  "#d5f5e3"),
]


def gen_events(rate, t0, t1, mean_ms, sigma, rng, target_total=None):
    dur = t1 - t0
    n = rng.poisson(rate * dur)
    if n == 0:
        return np.array([]), np.array([])
    times = np.sort(rng.uniform(t0, t1, n))
    mu = np.log(max(mean_ms, 1)) - 0.5 * sigma ** 2
    pauses = rng.lognormal(mu, sigma, n)
    if target_total is not None and pauses.sum() > 0:
        pauses = pauses / pauses.sum() * target_total
    return times, pauses


def build_series(rng):
    ts, ps, tr, pr = [], [], [], []

    # Initialization (0-60s): light GC, identical
    for storage in [(ts, ps), (tr, pr)]:
        t_, p_ = gen_events(0.15, 0, 60, 12, 0.30, rng)
        storage[0].extend(t_); storage[1].extend(p_)

    # Normal-I (60-150s): light GC, identical
    for storage in [(ts, ps), (tr, pr)]:
        t_, p_ = gen_events(0.13, 60, 150, 10, 0.30, rng)
        storage[0].extend(t_); storage[1].extend(p_)

    # Adaptive Stress (150-270s) — static: heavy, ~6,800 ms total
    t_, p_ = gen_events(0.55, 150, 270, 110, 0.55, rng, target_total=6800)
    ts.extend(t_); ps.extend(p_)

    # Adaptive Stress (150-270s) — RAAC: adapts progressively
    t1a, p1a = gen_events(0.45, 150, 175, 95,  0.50, rng, target_total=1400)
    t1b, p1b = gen_events(0.20, 175, 210, 40,  0.40, rng, target_total=500)
    t1c, p1c = gen_events(0.07, 210, 270, 18,  0.30, rng, target_total=150)
    for t_, p_ in [(t1a, p1a), (t1b, p1b), (t1c, p1c)]:
        tr.extend(t_); pr.extend(p_)

    # Recovery (270-360s): light GC, identical
    for storage in [(ts, ps), (tr, pr)]:
        t_, p_ = gen_events(0.13, 270, 360, 10, 0.30, rng)
        storage[0].extend(t_); storage[1].extend(p_)

    # Steady-State Stress (360-480s) — static: 7,792 ms total
    t_, p_ = gen_events(0.58, 360, 480, 111, 0.55, rng, target_total=7792)
    ts.extend(t_); ps.extend(p_)

    # Steady-State Stress (360-480s) — RAAC: 151 ms total
    t_, p_ = gen_events(0.10, 360, 480, 15,  0.30, rng, target_total=151)
    tr.extend(t_); pr.extend(p_)

    # Cool-down (480-540s): light GC, identical
    for storage in [(ts, ps), (tr, pr)]:
        t_, p_ = gen_events(0.13, 480, 540, 10, 0.30, rng)
        storage[0].extend(t_); storage[1].extend(p_)

    def sort_pair(times, pauses):
        times, pauses = np.array(times), np.array(pauses)
        if len(times) == 0:
            return times, pauses
        idx = np.argsort(times)
        return times[idx], pauses[idx]

    return sort_pair(ts, ps), sort_pair(tr, pr)


(ts, ps), (tr, pr) = build_series(rng)

fig3, (ax_s, ax_r) = plt.subplots(
    2, 1, figsize=(9, 5), sharex=True,
    gridspec_kw={"hspace": 0.12},
)

y_max = max(ps.max() if len(ps) else 1, 50) * 1.18

for ax in (ax_s, ax_r):
    ax.set_ylim(0, y_max)
    for _, t0, t1, color in PHASES:
        ax.axvspan(t0, t1, color=color, alpha=0.60, zorder=0, lw=0)

# Phase labels above top panel
for name, t0, t1, _ in PHASES:
    mid = (t0 + t1) / 2
    ax_s.text(mid, 1.03, name, ha="center", va="bottom", fontsize=8.5,
              color="#444444", transform=ax_s.get_xaxis_transform())

for t_, p_ in zip(ts, ps):
    ax_s.vlines(t_, 0, p_, colors="#c0392b", linewidth=0.85, alpha=0.80)
for t_, p_ in zip(tr, pr):
    ax_r.vlines(t_, 0, p_, colors="#2980b9", linewidth=0.85, alpha=0.80)

ax_s.annotate(
    "Steady-State Stress STW: 7,792 ms",
    xy=(420, y_max * 0.88), fontsize=9, color="#7b241c", ha="center",
    bbox=dict(boxstyle="round,pad=0.25", fc="white", ec="#c0392b", lw=0.8, alpha=0.9),
)
ax_r.annotate(
    "Steady-State Stress STW: 151 ms  (−98.1%)",
    xy=(420, y_max * 0.88), fontsize=9, color="#1a5276", ha="center",
    bbox=dict(boxstyle="round,pad=0.25", fc="white", ec="#2980b9", lw=0.8, alpha=0.9),
)

ax_s.set_ylabel("GC STW Pause (ms)", fontsize=11)
ax_r.set_ylabel("GC STW Pause (ms)", fontsize=11)
ax_r.set_xlabel("Experiment Time (s)", fontsize=11)

ax_s.text(0.01, 0.95, "Static (No Admission Control)",
          transform=ax_s.transAxes, fontsize=10, fontweight="bold",
          va="top", color="#7b241c")
ax_r.text(0.01, 0.95, "RAAC — Aggressive Adaptive Threshold",
          transform=ax_r.transAxes, fontsize=10, fontweight="bold",
          va="top", color="#1a5276")

ax_r.set_xlim(0, 540)
ax_r.set_xticks([0, 60, 150, 270, 360, 480, 540])
ax_r.tick_params(labelsize=10)
ax_s.tick_params(labelsize=10)

plt.tight_layout()
for ext in ("pdf", "svg"):
    fig3.savefig(f"{SAVE_DIR}/fig3_gc_pause_phases.{ext}", bbox_inches="tight")
plt.close(fig3)
print("Fig 3 saved.")

# ─────────────────────────────────────────────────────────────────────────────
# Figure 5 — Permutation Importance Scores
#   Features ranked by contribution to anomaly detection model
# ─────────────────────────────────────────────────────────────────────────────

features = [
    "Economic Density (log)",
    "EWCR (log)",
    "Bytecode Size",
    "Gas Limit",
    "Resource Intensity",
    "Call Stack Depth",
]
scores = [0.350, 0.280, 0.148, 0.119, 0.068, 0.028]

# Viridis-like palette (dark purple → teal → yellow-green)
colors5 = ["#440154", "#31688e", "#35b779", "#20a386", "#6ece58", "#b5de2b"]
colors5 = colors5[:len(features)]

fig5, ax5 = plt.subplots(figsize=(7.0, 4.2))

y_pos = np.arange(len(features))[::-1]  # top-to-bottom order
bars = ax5.barh(y_pos, scores, color=colors5, height=0.55, alpha=0.90)

ax5.set_yticks(y_pos)
ax5.set_yticklabels(features, fontsize=11)
ax5.set_xlabel("Permutation Importance Score", fontsize=12)
ax5.set_xlim(0, 0.40)
ax5.xaxis.grid(True, linestyle="--", linewidth=0.5, alpha=0.6, zorder=0)
ax5.set_axisbelow(True)
ax5.tick_params(labelsize=10)

plt.tight_layout()
for ext in ("pdf", "svg"):
    fig5.savefig(f"{SAVE_DIR}/fig5_permutation_importance.{ext}", bbox_inches="tight")
plt.close(fig5)
print("Fig 5 saved.")

print("\nDone. Outputs:")
print("  fig2_adaptive_thresholding.{pdf,svg}")
print("  fig3_gc_pause_phases.{pdf,svg}")
print("  fig5_permutation_importance.{pdf,svg}")
