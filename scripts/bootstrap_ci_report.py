#!/usr/bin/env python3.11
"""
Bootstrap-CI statistical report for RAAC multi-arm GC-pause results.

Georges/Buytaert/Eeckhout (OOPSLA 2007) argue that a single JVM-invocation's
internal repetitions aren't independent (JIT/heap-history carries over), so
multiple independent process invocations plus a confidence interval — not a
bare mean over n=3 — is the right way to report JVM performance numbers. This
script implements that for RAAC's per-arm GC-pause measurements: percentile
bootstrap CI (not a t-CI) because the data is visibly skewed/bimodal (some
aggressive runs fully suppress GC and land at/near 0ms).

Expects a results directory of subdirs named "<arm>_<rep>" (e.g.
"static_besu_1", "raac_moderate_besu_7"), each containing a "gc_summary.txt"
with either a numeric total STW ms value or the literal "no_gc_events"
(treated as 0).

Usage:
  python3 bootstrap_ci_report.py --results-dir <dir> --baseline static \
      --resamples 10000 --out report.md
"""
import argparse
import json
import re
import sys
from pathlib import Path

try:
    import numpy as np
except ImportError:
    print("ERROR: numpy required", file=sys.stderr)
    sys.exit(1)


_TS_RE = re.compile(r"^\d{4}\.\d{2}\.\d{2}-(\d{2}):(\d{2}):(\d{2})\.(\d{3})")


def _wall_clock_seconds(caliper_log: Path):
    """First-to-last timestamped-line span in caliper.log, as a wall-clock
    duration proxy for this rep (independent of whether it completed).
    Returns None if the file is missing/unparseable."""
    if not caliper_log.exists():
        return None
    first_s = last_s = None
    try:
        with caliper_log.open(errors="replace") as fh:
            for line in fh:
                m = _TS_RE.match(line)
                if not m:
                    continue
                h, mi, s, ms = (int(x) for x in m.groups())
                t = h * 3600 + mi * 60 + s + ms / 1000.0
                if first_s is None:
                    first_s = t
                last_s = t
    except OSError:
        return None
    if first_s is None or last_s is None:
        return None
    span = last_s - first_s
    # Guard against a single UTC-midnight wraparound within one rep's log.
    if span < 0:
        span += 24 * 3600
    return span


def _round_completed(caliper_log: Path):
    """Whether this rep reached the final round (calm-3 / Round 5)."""
    if not caliper_log.exists():
        return None
    try:
        text = caliper_log.read_text(errors="replace")
    except OSError:
        return None
    return "calm-3 Round 5" in text


_ROUND_RE = re.compile(r"(?:calm-1|attack-burst-1|calm-2|attack-burst-2|calm-3) Round (\d+)")


def _rounds_survived(caliper_log: Path):
    """How many of the 5 post-warmup rounds this rep reached (0-5), from the
    highest 'Round N' marker seen for calm-1/attack-burst-1/calm-2/
    attack-burst-2/calm-3. Redesign debate (raac-experiment-redesign,
    2026-07-24) finding: binary round-completion can't distinguish a rep that
    died in round 1 from one that died in round 4 -- this graduated count is
    the headline metric recommended in that debate's synthesis. Counts
    'reached' (round marker seen at least once), not 'fully completed' --
    round 5 reached is equivalent to the old binary _round_completed()."""
    if not caliper_log.exists():
        return None
    try:
        text = caliper_log.read_text(errors="replace")
    except OSError:
        return None
    rounds = [int(m.group(1)) for m in _ROUND_RE.finditer(text)]
    return max(rounds) if rounds else 0


def load_arm_values(results_dir: Path):
    """Return {arm_name: [{"gc_ms":.., "wall_s":.., "completed":bool,
    "rounds_survived":int|None}, ...]} scanning <arm>_<rep> subdirs."""
    arms = {}
    for d in sorted(results_dir.iterdir()):
        if not d.is_dir():
            continue
        m = re.match(r"^(.+)_(\d+)$", d.name)
        if not m:
            continue
        arm = m.group(1)
        summary_path = d / "gc_summary.txt"
        if not summary_path.exists():
            continue
        raw = summary_path.read_text().strip()
        if raw in ("", "no_gc_events", "parse_error"):
            val = 0.0
        else:
            try:
                val = float(raw)
            except ValueError:
                continue
        wall_s = _wall_clock_seconds(d / "caliper.log")
        completed = _round_completed(d / "caliper.log")
        rounds_survived = _rounds_survived(d / "caliper.log")
        arms.setdefault(arm, []).append({
            "gc_ms": val, "wall_s": wall_s, "completed": completed,
            "rounds_survived": rounds_survived,
        })
    return arms


def percentile_bootstrap_ci(values, resamples=10000, alpha=0.05, seed=42):
    rng = np.random.default_rng(seed)
    values = np.asarray(values, dtype=float)
    n = len(values)
    boot_means = np.empty(resamples)
    for i in range(resamples):
        sample = rng.choice(values, size=n, replace=True)
        boot_means[i] = sample.mean()
    lo = np.percentile(boot_means, 100 * (alpha / 2))
    hi = np.percentile(boot_means, 100 * (1 - alpha / 2))
    return lo, hi


def summarize(records, resamples):
    """records: list of {"gc_ms":.., "wall_s":.., "completed":bool|None}.

    Reports raw totals (as before, for continuity) AND wall-clock-duty-cycle-
    normalized pause (pause_ms / wall_clock_ms) plus round-completion rate.
    The raw-total comparison across arms is NOT apples-to-apples when
    completion rates differ (a rep killed early after stalling, vs. one that
    ran the full round pattern, spend very different wall-clock time
    accumulating pause) -- see raac_nm_round3_stall_bug memory. Report both,
    but treat completion rate + duty cycle as the trustworthy comparison.
    """
    values = [r["gc_ms"] for r in records]
    arr = np.asarray(values, dtype=float)
    n = len(arr)
    mean = float(arr.mean())
    median = float(np.median(arr))
    std = float(arr.std(ddof=1)) if n > 1 else 0.0
    ci_lo, ci_hi = percentile_bootstrap_ci(arr, resamples=resamples) if n > 1 else (mean, mean)
    suppressed = int((arr <= 1.0).sum())  # "fully suppressed" ~ 0ms (allow 1ms float slack)

    completions = [r["completed"] for r in records if r["completed"] is not None]
    n_completed = sum(1 for c in completions if c)
    n_completion_known = len(completions)

    duty = []
    for r in records:
        if r["wall_s"] and r["wall_s"] > 0:
            duty.append(r["gc_ms"] / (r["wall_s"] * 1000.0))
    duty_arr = np.asarray(duty, dtype=float)
    duty_mean = float(duty_arr.mean()) if len(duty_arr) else None
    duty_ci_lo, duty_ci_hi = (percentile_bootstrap_ci(duty_arr, resamples=resamples)
                              if len(duty_arr) > 1 else (duty_mean, duty_mean))

    rounds = [r["rounds_survived"] for r in records if r["rounds_survived"] is not None]
    rounds_arr = np.asarray(rounds, dtype=float)
    rounds_survived_mean = float(rounds_arr.mean()) if len(rounds_arr) else None
    rounds_ci_lo, rounds_ci_hi = (percentile_bootstrap_ci(rounds_arr, resamples=resamples)
                                  if len(rounds_arr) > 1 else (rounds_survived_mean, rounds_survived_mean))
    rounds_survived_ratio = (rounds_survived_mean / 5.0) if rounds_survived_mean is not None else None

    return {
        "n": n, "mean": mean, "median": median, "std": std,
        "ci95_lo": float(ci_lo), "ci95_hi": float(ci_hi),
        "gc_suppressed_ratio": f"{suppressed}/{n}",
        "values": arr.tolist(),
        "round_completion_ratio": f"{n_completed}/{n_completion_known}" if n_completion_known else "n/a",
        "round_completion_rate": (n_completed / n_completion_known) if n_completion_known else None,
        "duty_cycle_mean": duty_mean,
        "duty_cycle_ci95_lo": float(duty_ci_lo) if duty_ci_lo is not None else None,
        "duty_cycle_ci95_hi": float(duty_ci_hi) if duty_ci_hi is not None else None,
        "rounds_survived_mean": rounds_survived_mean,
        "rounds_survived_ci95_lo": float(rounds_ci_lo) if rounds_ci_lo is not None else None,
        "rounds_survived_ci95_hi": float(rounds_ci_hi) if rounds_ci_hi is not None else None,
        "rounds_survived_ratio": rounds_survived_ratio,
    }


def main():
    ap = argparse.ArgumentParser(description="Bootstrap CI report for RAAC multi-arm results")
    ap.add_argument("--results-dir", required=True)
    ap.add_argument("--baseline", default="static", help="arm name to compute relative reduction against")
    ap.add_argument("--resamples", type=int, default=10000)
    ap.add_argument("--out", default=None, help="markdown output path (also prints to stdout)")
    ap.add_argument("--out-json", default=None)
    args = ap.parse_args()

    results_dir = Path(args.results_dir)
    arms = load_arm_values(results_dir)
    if not arms:
        print(f"ERROR: no <arm>_<rep> subdirs with gc_summary.txt found under {results_dir}", file=sys.stderr)
        sys.exit(1)

    summaries = {arm: summarize(vals, args.resamples) for arm, vals in arms.items()}

    baseline_mean = summaries.get(args.baseline, {}).get("mean")
    baseline_duty = summaries.get(args.baseline, {}).get("duty_cycle_mean")

    lines = []
    lines.append(f"# GC Pause Bootstrap-CI Report — {results_dir.name}\n")

    lines.append("## Headline: Round-Completion Rate (node survival)\n")
    lines.append(
        "A rep that never reaches the final round (`calm-3`/Round 5) means the "
        "node stopped responding to RPC before the workload finished -- a "
        "different, more severe outcome than \"high GC pause but still "
        "responsive\". Raw total-pause comparisons below are NOT apples-to-"
        "apples across arms with different completion rates (a killed-early "
        "rep and a fully-completed rep spend very different wall-clock time "
        "accumulating pause) -- see raac_nm_round3_stall_bug memory. Treat "
        "this table, and the duty-cycle table below it, as the trustworthy "
        "comparison; the raw-totals table is kept for continuity/reference "
        "only.\n"
    )
    lines.append(
        "`Rounds survived` (0-5, bootstrap CI) is the graduated companion to "
        "the binary completion rate -- a rep that dies in round 4 is a very "
        "different outcome from one that dies in round 1, which the binary "
        "rate alone can't distinguish (redesign debate, "
        "raac-experiment-redesign, 2026-07-24).\n"
    )
    lines.append("| Arm | Completed all 5 rounds | Completion rate | Rounds survived (0-5) | 95% CI |")
    lines.append("|---|---|---|---|---|")
    for arm, s in sorted(summaries.items(), key=lambda kv: (kv[1]["round_completion_rate"] or 0), reverse=True):
        rate_str = f"{(s['round_completion_rate']*100):.0f}%" if s['round_completion_rate'] is not None else "n/a"
        if s["rounds_survived_mean"] is not None:
            rs_str = f"{s['rounds_survived_mean']:.2f}"
            rs_ci_str = f"[{s['rounds_survived_ci95_lo']:.2f}, {s['rounds_survived_ci95_hi']:.2f}]"
        else:
            rs_str = "n/a"
            rs_ci_str = "n/a"
        lines.append(f"| {arm} | {s['round_completion_ratio']} | {rate_str} | {rs_str} | {rs_ci_str} |")
    lines.append("")

    lines.append("## Secondary: GC Duty Cycle (pause-ms per wall-clock ms, bootstrap CI)\n")
    lines.append(
        "Normalizes for reps that ran longer (e.g. stalled and were killed by "
        "the harness timeout) vs. reps that completed promptly -- a fairer "
        "cross-arm comparison than raw totals when completion rates differ.\n"
    )
    lines.append("| Arm | n (with wall-clock data) | Duty cycle | 95% CI | vs baseline |")
    lines.append("|---|---|---|---|---|")
    for arm, s in sorted(summaries.items(),
                         key=lambda kv: (kv[1]["duty_cycle_mean"] if kv[1]["duty_cycle_mean"] is not None else -1),
                         reverse=True):
        if s["duty_cycle_mean"] is None:
            lines.append(f"| {arm} | 0 | n/a | n/a | n/a |")
            continue
        vs_baseline = "—"
        if baseline_duty and arm != args.baseline and baseline_duty > 0:
            pct = 100.0 * (s["duty_cycle_mean"] - baseline_duty) / baseline_duty
            vs_baseline = f"{pct:+.1f}%"
        lines.append(
            f"| {arm} | {s['n']} | {s['duty_cycle_mean']:.4f} | "
            f"[{s['duty_cycle_ci95_lo']:.4f}, {s['duty_cycle_ci95_hi']:.4f}] | {vs_baseline} |"
        )
    lines.append("")

    lines.append("## Reference: Raw Total GC Pause (original metric, kept for continuity)\n")
    lines.append(f"Percentile bootstrap CI, {args.resamples} resamples, 95% interval. "
                 f"'GC suppressed' = runs with total STW pause <= 1ms. **Caveat: not "
                 f"normalized by wall-clock duration or completion status -- see headline "
                 f"table above before drawing conclusions from this table alone.**\n")
    lines.append("| Arm | n | Mean (ms) | Median (ms) | 95% CI (ms) | vs baseline | GC suppressed |")
    lines.append("|---|---|---|---|---|---|---|")
    for arm, s in sorted(summaries.items(), key=lambda kv: kv[1]["mean"], reverse=True):
        vs_baseline = "—"
        if baseline_mean and arm != args.baseline and baseline_mean > 0:
            pct = 100.0 * (s["mean"] - baseline_mean) / baseline_mean
            vs_baseline = f"{pct:+.1f}%"
        lines.append(
            f"| {arm} | {s['n']} | {s['mean']:.1f} | {s['median']:.1f} | "
            f"[{s['ci95_lo']:.1f}, {s['ci95_hi']:.1f}] | {vs_baseline} | {s['gc_suppressed_ratio']} |"
        )

    report = "\n".join(lines) + "\n"
    print(report)

    if args.out:
        Path(args.out).write_text(report)
        print(f"[report] wrote {args.out}", file=sys.stderr)
    if args.out_json:
        Path(args.out_json).write_text(json.dumps(summaries, indent=2))
        print(f"[report] wrote {args.out_json}", file=sys.stderr)


if __name__ == "__main__":
    main()
