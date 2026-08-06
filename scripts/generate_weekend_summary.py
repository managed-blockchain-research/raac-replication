#!/usr/bin/env python3
"""Generate a single human-readable summary after the unattended weekend run
(run_all_tonight_now.sh: fragmentation-fix + ML-ablation -> Besu 6-arm n=8 ->
NM 6-arm n=8). Meant to be read cold on Monday morning -- no need to dig
through individual caliper_console.log files first.

Scans every run directory recorded in the LATEST_*_RESULTS_DIR.txt pointer
files, re-applies check_run_health.py's logic to each (independent of
whatever the pipeline's own retry loop decided, as a final cross-check),
and reports:
  - per-phase / per-arm rep counts (healthy vs anomalous)
  - contents of ANOMALOUS_RUNS.txt (per-results-dir) and the global
    NEEDS_ATTENTION_URGENT.txt, if any
  - one clear top-line verdict: CLEAN / NEEDS REVIEW / CIRCUIT BROKEN
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from check_run_health import check_run  # noqa: E402

BASE = Path("/home/yeochan.yoon/caliper-stress-test")
POINTER_FILES = {
    "Fragmentation-fix": BASE / "LATEST_FRAGMENTATION_FIX_RESULTS_DIR.txt",
    "ML-ablation": BASE / "LATEST_ML_ABLATION_RESULTS_DIR.txt",
    "Besu 6-arm": BASE / "LATEST_FULL6ARM_RESULTS_DIR.txt",
    "NM 6-arm": BASE / "LATEST_NM_FULL6ARM_RESULTS_DIR.txt",
}
NEEDS_ATTENTION = BASE / "NEEDS_ATTENTION_URGENT.txt"


def scan_results_dir(results_dir: Path):
    """Returns {arm_name: {"healthy": n, "anomalous": n, "anomalous_labels": [...]}}"""
    per_arm = {}
    if not results_dir.exists():
        return per_arm
    for run_dir in sorted(results_dir.iterdir()):
        if not run_dir.is_dir() or run_dir.name.endswith((".txt",)):
            continue
        if "_BAD_attempt" in run_dir.name or "_SUPERSEDED_" in run_dir.name:
            continue  # superseded attempts, not final data
        if not (run_dir / "caliper_console.log").exists() and not (run_dir / "FAILED").exists():
            continue  # not a run dir (e.g. a symlinked-in arm from another results dir, or stray file)
        # arm name = label minus trailing _<platform>_<rep>, e.g. "static_besu_3" -> "static_besu"
        parts = run_dir.name.rsplit("_", 1)
        arm = parts[0] if len(parts) == 2 and parts[1].isdigit() else run_dir.name
        anomalies, notes = check_run(run_dir, return_notes=True)
        bucket = per_arm.setdefault(arm, {"healthy": 0, "anomalous": 0, "anomalous_labels": [], "notes": []})
        if anomalies:
            bucket["anomalous"] += 1
            bucket["anomalous_labels"].append((run_dir.name, anomalies))
        else:
            bucket["healthy"] += 1
        for n in notes:
            bucket["notes"].append((run_dir.name, n))
    return per_arm


def main():
    lines = []
    lines.append("# RAAC Weekend Run Summary")
    lines.append("")
    overall_bad = False
    circuit_broken = False

    for phase_name, pointer_file in POINTER_FILES.items():
        lines.append(f"## {phase_name}")
        if not pointer_file.exists():
            lines.append("- NOT STARTED (no results dir pointer found)")
            lines.append("")
            overall_bad = True
            continue
        results_dir = Path(pointer_file.read_text().strip())
        lines.append(f"- Results dir: `{results_dir}`")
        per_arm = scan_results_dir(results_dir)
        if not per_arm:
            lines.append("- NO RUNS FOUND in results dir (phase may not have produced any completed reps)")
            overall_bad = True
        for arm, stats in sorted(per_arm.items()):
            total = stats["healthy"] + stats["anomalous"]
            marker = "OK" if stats["anomalous"] == 0 else "ISSUES"
            lines.append(f"- `{arm}`: {stats['healthy']}/{total} healthy [{marker}]")
            if stats["anomalous"]:
                overall_bad = True
                for label, anomalies in stats["anomalous_labels"]:
                    lines.append(f"    - {label}:")
                    for a in anomalies:
                        lines.append(f"        - {a}")
            if stats["notes"]:
                for label, note in stats["notes"]:
                    lines.append(f"    - (info, not an anomaly) {label}: {note}")
        anomalous_runs_file = results_dir / "ANOMALOUS_RUNS.txt"
        if anomalous_runs_file.exists():
            lines.append(f"- NOTE: {anomalous_runs_file} exists (pipeline's own retry loop already flagged issues here)")
        lines.append("")

    lines.append("## Circuit breaker / urgent flags")
    if NEEDS_ATTENTION.exists():
        circuit_broken = True
        overall_bad = True
        lines.append("- `NEEDS_ATTENTION_URGENT.txt` EXISTS -- at least one phase stopped early due to repeated anomalies:")
        lines.append("```")
        lines.append(NEEDS_ATTENTION.read_text().strip())
        lines.append("```")
    else:
        lines.append("- none (no phase tripped its circuit breaker)")
    lines.append("")

    lines.append("## Verdict")
    if circuit_broken:
        lines.append("**CIRCUIT BROKEN** -- at least one phase stopped itself early. Needs root-cause diagnosis before re-running that phase. Do NOT treat partial data from the broken phase as final.")
    elif overall_bad:
        lines.append("**NEEDS REVIEW** -- some runs were flagged anomalous (see details above). Data from healthy runs is likely usable; anomalous ones should be re-run or excluded before analysis.")
    else:
        lines.append("**CLEAN** -- all phases ran, all reps found passed the health check (no permanently-stuck rounds, no elevated calm-round fail rates, no crash signatures).")

    summary_path = BASE / "MONDAY_SUMMARY.md"
    summary_path.write_text("\n".join(lines) + "\n")
    print(f"Wrote {summary_path}")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
