import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

plt.rcParams.update({
    "font.size": 9, "axes.labelsize": 9, "axes.titlesize": 9,
    "legend.fontsize": 6.5, "xtick.labelsize": 8, "ytick.labelsize": 8,
    "font.family": "serif",
})

policies = ["static", "native_evict", "heap_only", "dagor", "token_bucket", "moderate", "aggressive"]
labels   = ["Static", "Native\nEvict", "Heap\nOnly", "Dagor", "Token\nBucket", "Moderate", "Aggressive"]
colors   = ["#555555", "#c1440e", "#2e7d32", "#8e44ad", "#d4a017", "#1f6f8b", "#1f4e8c"]

data = {
    0:  {"static":(986.8,676.8,1591.8),"native_evict":(602.7,564.0,632.0),"heap_only":(618.6,505.6,684.8),
         "dagor":(1005.8,655.6,1694.8),"token_bucket":(715.3,677.0,790.0),"moderate":(811.6,678.6,1073.4),
         "aggressive":(674.2,661.8,694.6)},
    25: {"static":(687.2,676.0,695.4),"native_evict":(630.7,587.0,705.0),"heap_only":(582.7,398.0,694.0),
         "dagor":(706.0,693.6,718.8),"token_bucket":(824.0,709.0,909.0),"moderate":(672.7,666.0,680.0),
         "aggressive":(586.0,404.0,685.0)},
    75: {"static":(821.7,675.0,1078.0),"native_evict":(866.3,434.0,1391.0),"heap_only":(598.8,429.8,685.7),
         "dagor":(806.8,692.8,959.2),"token_bucket":(695.6,673.4,717.8),"moderate":(707.7,698.0,721.0),
         "aggressive":(355.7,177.0,456.0)},
}

fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.6), gridspec_kw={"width_ratios": [1.7, 1]})

# Panel (a): grouped bars, GC pause by policy x intensity
ax = axes[0]
intensities = [0, 25, 75]
n_pol = len(policies)
bar_w = 0.11
x = np.arange(len(intensities))
for i, p in enumerate(policies):
    means = [data[it][p][0] for it in intensities]
    lo    = [data[it][p][0] - data[it][p][1] for it in intensities]
    hi    = [data[it][p][2] - data[it][p][0] for it in intensities]
    offset = (i - n_pol/2 + 0.5) * bar_w
    ax.bar(x + offset, means, width=bar_w, color=colors[i], label=labels[i].replace("\n", " "),
           yerr=[lo, hi], capsize=1.5, error_kw={"linewidth": 0.6})
ax.set_xticks(x)
ax.set_xticklabels(["0%", "25%", "75%"])
ax.set_xlabel("Attack intensity (attackRatio)")
ax.set_ylabel("GC pause (ms, 95% CI)")
ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.22), ncol=4, frameon=False, fontsize=6)

# Panel (b): Native Evict calm-round fail rate. Aggregated directly from
# each rep's report.html Succ/Fail columns over all "calm-*" rounds
# (n=3 reps/intensity); supersedes an earlier hand-computed 18.37/18.58/
# 19.12 that could not be reproduced against report.html (see the
# heap-size-sweep figure's own correction note, 2026-09-26).
ax = axes[1]
rates = [3.68, 3.68, 3.68]
ax.plot(intensities, rates, marker="o", color="#c1440e", linewidth=1.6, markersize=5)
ax.set_ylim(0, 6)
ax.set_xticks(intensities)
ax.set_xticklabels(["0%", "25%", "75%"])
ax.set_xlabel("Attack intensity (attackRatio)")
ax.set_ylabel("Native Evict benign-tx\nfail rate (%)")
for xi, yi in zip(intensities, rates):
    ax.annotate(f"{yi:.2f}%", (xi, yi), textcoords="offset points", xytext=(0, 8),
                ha="center", fontsize=7)

fig.tight_layout(rect=[0, 0.06, 1, 1])
fig.text(0.315, 0.02, "(a) GC pause by policy and intensity", ha="center", fontsize=8.5)
fig.text(0.81, 0.02, "(b) Native Evict collateral cost", ha="center", fontsize=8.5)
fig.savefig("/home/yeochan.yoon/banning-worktrees/raac-revision/papers/raac/raac_fig7_pareto.pdf")
fig.savefig("/home/yeochan.yoon/banning-worktrees/raac-revision/papers/raac/raac_fig7_pareto.png", dpi=200)
print("done")
