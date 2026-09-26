import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

plt.rcParams.update({
    "font.size": 9,
    "axes.labelsize": 9,
    "axes.titlesize": 9,
    "legend.fontsize": 8,
    "xtick.labelsize": 8,
    "ytick.labelsize": 8,
    "font.family": "serif",
})

shapes = [96000, 48000, 24000, 12000, 6000, 3000]

# --- Besu: GC duty cycle (per-mille) ---
besu_static = [1.1, 0.9, 0.7, 0.6, 0.5, 0.5]
besu_aggr   = [1.0, 0.7, 0.6, 0.5, 0.5, 0.4]
besu_static_mixed = 0.7
besu_aggr_mixed = 0.7
# individual reps at 96000B, aggressive (raw ms) -> approx duty-cycle equivalent
besu_aggr96_raw_ms = [397, 439, 696, 702, 705, 705, 715, 716, 718, 738]
conv = 1.0 / (sum(besu_aggr96_raw_ms) / len(besu_aggr96_raw_ms))  # scale so mean maps to 1.0 permille
besu_aggr96_scatter = [v * conv for v in besu_aggr96_raw_ms]

# --- Nethermind: GC time (ms) ---
nm_static = [323.5, 232.4, 115.7, 101.6, 72.3, 72.1]
nm_aggr   = [8.6, 1.7, 2.0, 8.1, 2.1, 2.0]
nm_static_mixed = 236.1
nm_aggr_mixed = 1.4
LOH_THRESHOLD = 85000

fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.0))

# Panel (a): Besu
ax = axes[0]
ax.plot(shapes, besu_static, marker="o", color="#1f4e8c", linewidth=1.6,
        markersize=5, label="Static", zorder=3)
ax.plot(shapes, besu_aggr, marker="s", color="#c1440e", linewidth=1.6,
        linestyle="--", markersize=5, label="Aggressive", zorder=3)
jitter = np.linspace(-0.06, 0.06, len(besu_aggr96_scatter))
ax.scatter([96000 * (1 + j) for j in jitter], besu_aggr96_scatter,
           s=10, color="#c1440e", alpha=0.55, zorder=2,
           label="Aggressive, 96 KB (individual reps)")
ax.axhline(besu_static_mixed, color="#1f4e8c", linestyle=":", linewidth=1.1, zorder=1)
ax.axhline(besu_aggr_mixed, color="#c1440e", linestyle=":", linewidth=1.1, zorder=1)
ax.text(3000 * 0.85, besu_static_mixed + 0.03, "Mixed (Static)", fontsize=6.5,
        color="#1f4e8c", ha="left", va="bottom")
ax.text(3000 * 0.85, besu_aggr_mixed - 0.09, "Mixed (Aggressive)", fontsize=6.5,
        color="#c1440e", ha="left", va="top")
ax.set_xscale("log")
ax.invert_xaxis()
ax.set_xlabel("Attack payload size (bytes, log scale)")
ax.set_ylabel("GC duty cycle (‰ of wall-clock)")
ax.legend(loc="upper left", frameon=False, fontsize=6.5)
ax.set_ylim(0, 1.35)

# Panel (b): Nethermind
ax = axes[1]
ax.plot(shapes, nm_static, marker="o", color="#1f4e8c", linewidth=1.6,
        markersize=5, label="Static", zorder=3)
ax.plot(shapes, nm_aggr, marker="s", color="#c1440e", linewidth=1.6,
        linestyle="--", markersize=5, label="Aggressive", zorder=3)
ax.axhline(nm_static_mixed, color="#1f4e8c", linestyle=":", linewidth=1.1, zorder=1)
ax.axhline(nm_aggr_mixed, color="#c1440e", linestyle=":", linewidth=1.1, zorder=1)
ax.text(3000 * 0.85, nm_static_mixed * 1.08, "Mixed (Static)", fontsize=6.5,
        color="#1f4e8c", ha="left", va="bottom")
ax.text(3000 * 0.85, nm_aggr_mixed * 0.65, "Mixed (Aggressive)", fontsize=6.5,
        color="#c1440e", ha="left", va="top")
ax.axvline(LOH_THRESHOLD, color="gray", linestyle="--", linewidth=1.0, zorder=1)
ax.annotate("LOH threshold\n(85 KB)", xy=(LOH_THRESHOLD, 400), xytext=(30000, 400),
            fontsize=6.5, color="gray", ha="center", va="center",
            arrowprops=dict(arrowstyle="-", color="gray", linewidth=0.8))
ax.set_xscale("log")
ax.set_yscale("log")
ax.invert_xaxis()
ax.set_xlabel("Attack payload size (bytes, log scale)")
ax.set_ylabel("GC time (ms, log scale)")
ax.legend(loc="lower left", frameon=False, fontsize=6.5)

fig.tight_layout(rect=[0, 0.08, 1, 1])
fig.text(0.27, 0.0, "(a) Besu", ha="center", fontsize=9)
fig.text(0.77, 0.0, "(b) Nethermind", ha="center", fontsize=9)
fig.savefig("/home/yeochan.yoon/banning-worktrees/raac-revision/papers/raac/raac_fig8_shape_sweep.pdf")
fig.savefig("/home/yeochan.yoon/banning-worktrees/raac-revision/papers/raac/raac_fig8_shape_sweep.png", dpi=200)
print("done")
