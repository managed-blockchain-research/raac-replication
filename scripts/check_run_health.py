#!/usr/bin/env python3
"""Post-hoc health check for one RAAC run directory (Besu or NM).

Catches the failure mode the existing infra-retry in run_raac_full_6arm.sh /
run_raac_nm_full_6arm.sh does NOT catch: a run that completes (rc=0 from
run_config/run_config_nm) but whose *results* are garbage -- permanently
stalled rounds, catastrophically slow rounds (client/host contention,
regressions like the 2026-07-31 nonce-race and maxSockets episodes), or a
high transaction failure rate. `wait "${caliper_pid}" || true` in run_config
means a timed-out/killed caliper process still returns 0, so this check is
the only thing standing between "ran but the data is unusable" and it
silently landing in the results directory.

Exit code 0 = healthy, 1 = anomalous (reasons printed on stdout, one per line,
prefixed "ANOMALY: ").
"""
import argparse
import json
import re
import sys
from pathlib import Path

# label -> nominal txDuration (seconds), from benchconfig-raac-burst-dynamic.yaml
NOMINAL_ROUND_SECONDS = {
    "warmup": 60,
    "calm-1": 90,
    "attack-burst-1": 120,
    "calm-2": 90,
    "attack-burst-2": 120,
    "calm-3": 60,
}
EXPECTED_ROUND_COUNT = len(NOMINAL_ROUND_SECONDS)

# attackRatio=0 for calm/warmup rounds (see benchconfig) -- these should
# ALWAYS behave near-perfectly regardless of policy/platform, so strict
# thresholds apply. attack-burst-* rounds have attackRatio=1 and are where
# admission-control policies are SUPPOSED to reject/slow traffic (that's the
# experimental treatment being measured, e.g. the documented NM finding that
# static can legitimately show high fail/low completion under attack) -- so
# SLOW/HIGH_FAIL are deliberately NOT checked there. INCOMPLETE (a round that
# never finishes at all -- a permanent client-side stall, not a resolved
# reject) and crash signatures are checked on every round regardless, since a
# transaction that gets rejected still resolves as Fail; only a genuine hang
# leaves it forever "Unfinished".
CALM_LABELS = {"warmup", "calm-1", "calm-2", "calm-3"}

SLOW_MULTIPLIER = 4.0       # actual > 4x nominal txDuration -> SLOW (calm rounds only)
SLOW_ABS_FLOOR = 120        # ... but never flag a round finishing within nominal+120s
FAIL_RATE_THRESHOLD = 0.15  # 15% failed transactions in a calm round -> HIGH_FAIL
MIN_TX_FOR_FAIL_CHECK = 50  # ignore fail-rate on rounds with too few tx to be meaningful

# Besu's own reference (aggressive_besu_1, healthy): attack-burst-1/2 complete
# in ~143s (nominal 120s) even under full attack load -- Besu's G1GC is
# documented to tolerate this workload well (see raac.tex abstract). So an
# attack round taking 20+ minutes on Besu is NOT legitimate backlog-momentum
# behavior (that finding is specific to NM's .NET GC/tx-pool interaction);
# on Besu it means the client is stalled (e.g. the 2026-07-31 socket-
# starvation bug: maxSockets=16 vs RAAC_MAX_INFLIGHT=50). Apply the same
# SLOW threshold to attack rounds too, but ONLY for Besu runs.
ATTACK_SLOW_MULTIPLIER_BESU = 4.0
ATTACK_SLOW_ABS_FLOOR_BESU = 240


def detect_platform(run_dir: Path):
    name = run_dir.name
    if "_besu_" in name:
        return "besu"
    if "_nm_" in name:
        return "nm"
    return "unknown"


def parse_round_durations(console_log_text):
    """Returns list of (round_index, label, duration_seconds_or_None)."""
    starts = re.findall(r"Started round (\d+) \(([\w-]+)\)", console_log_text)
    finishes = {
        (m.group(1), m.group(2)): float(m.group(3))
        for m in re.finditer(
            r"Finished round (\d+) \(([\w-]+)\) in ([\d.]+) seconds", console_log_text
        )
    }
    out = []
    for idx, label in starts:
        out.append((idx, label, finishes.get((idx, label))))
    return out


def parse_last_tx_summary_per_label(console_log_text):
    """Returns {label: (submitted, succ, fail, unfinished)} using the LAST
    'Transaction Info' line seen for each round label."""
    result = {}
    for m in re.finditer(
        r"\[([\w-]+) Round \d+ Transaction Info\] - Submitted: (\d+) Succ: (\d+) Fail:(\d+) Unfinished:(\d+)",
        console_log_text,
    ):
        label, submitted, succ, fail, unfinished = m.groups()
        result[label] = (int(submitted), int(succ), int(fail), int(unfinished))
    return result


def check_run(run_dir: Path, return_notes=False):
    """Returns anomalies (list). If return_notes=True, returns (anomalies, notes)
    where notes are informational-only observations that do NOT drive
    retry/circuit-breaker decisions (e.g. an attack-burst round never
    finishing -- for NM specifically this is a documented, legitimate
    "backlog momentum" finding (see project_raac_experiment_redesign memory:
    admission-control arms can show 0% completion under attack BY DESIGN),
    not necessarily a bug. Every genuine client-side hang observed empirically
    on 2026-07-31 (mi10/keepalive smoke tests) showed up on a CALM round
    instead, which is why only calm rounds drive hard failures here."""
    anomalies = []
    notes = []
    failed_marker = run_dir / "FAILED"
    if failed_marker.exists():
        anomalies.append(f"INFRA_FAILURE: FAILED marker present ({failed_marker.read_text().strip()})")
        return (anomalies, notes) if return_notes else anomalies

    console_log = run_dir / "caliper_console.log"
    if not console_log.exists():
        anomalies.append("MISSING: caliper_console.log not found")
        return (anomalies, notes) if return_notes else anomalies

    text = console_log.read_text(errors="replace")
    platform = detect_platform(run_dir)

    rounds = parse_round_durations(text)
    finished_count = sum(1 for _, _, dur in rounds if dur is not None)
    if finished_count < EXPECTED_ROUND_COUNT:
        never_finished = [label for _, label, dur in rounds if dur is None]
        never_finished_calm = [l for l in never_finished if l in CALM_LABELS]
        never_finished_attack = [l for l in never_finished if l not in CALM_LABELS]
        if never_finished_calm:
            anomalies.append(
                f"INCOMPLETE: only {finished_count}/{EXPECTED_ROUND_COUNT} rounds finished"
                + (f" (never finished: {never_finished_calm})" if never_finished_calm else "")
            )
        if never_finished_attack:
            if platform == "besu":
                anomalies.append(
                    f"INCOMPLETE: attack round(s) never finished on Besu: {never_finished_attack} "
                    f"-- Besu's own reference completes attack rounds in ~143s; this platform does "
                    f"not have NM's documented backlog-momentum exemption"
                )
            else:
                notes.append(
                    f"attack round(s) never finished: {never_finished_attack} -- NOT flagged as an "
                    f"anomaly (may be legitimate admission-control/backlog-momentum behavior, "
                    f"especially on NM; see project_raac_experiment_redesign memory)"
                )

    for _, label, dur in rounds:
        if dur is None:
            continue
        if label in CALM_LABELS:
            nominal = NOMINAL_ROUND_SECONDS.get(label)
            if nominal is None:
                continue
            threshold = max(nominal * SLOW_MULTIPLIER, nominal + SLOW_ABS_FLOOR)
            if dur > threshold:
                anomalies.append(
                    f"SLOW: calm round '{label}' took {dur:.1f}s (nominal {nominal}s, threshold {threshold:.0f}s)"
                )
        elif platform == "besu":
            nominal = NOMINAL_ROUND_SECONDS.get(label)
            if nominal is None:
                continue
            threshold = max(nominal * ATTACK_SLOW_MULTIPLIER_BESU, nominal + ATTACK_SLOW_ABS_FLOOR_BESU)
            if dur > threshold:
                anomalies.append(
                    f"SLOW: Besu attack round '{label}' took {dur:.1f}s (nominal {nominal}s, threshold "
                    f"{threshold:.0f}s) -- Besu's own reference completes this in ~143s"
                )

    tx_by_label = parse_last_tx_summary_per_label(text)
    for label, (submitted, succ, fail, unfinished) in tx_by_label.items():
        if label not in CALM_LABELS:
            continue
        total = succ + fail
        if total >= MIN_TX_FOR_FAIL_CHECK:
            fail_rate = fail / total
            if fail_rate > FAIL_RATE_THRESHOLD:
                anomalies.append(
                    f"HIGH_FAIL: calm round '{label}' fail rate {fail_rate:.1%} ({fail}/{total}) -- "
                    f"unexpected since attackRatio=0 for calm rounds"
                )

    # crash signatures in besu/nm console
    for console_name in ("besu_console.log", "nm_console.log"):
        p = run_dir / console_name
        if p.exists():
            ctext = p.read_text(errors="replace")
            if re.search(r"OutOfMemoryError|Fatal error|Killed process", ctext):
                anomalies.append(f"CRASH_SIGNATURE: found in {console_name}")

    return (anomalies, notes) if return_notes else anomalies


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", action="store_true", help="emit JSON instead of plain lines")
    args = ap.parse_args()

    anomalies, notes = check_run(args.run_dir, return_notes=True)

    if args.json:
        print(json.dumps({"run_dir": str(args.run_dir), "healthy": not anomalies, "anomalies": anomalies, "notes": notes}))
    else:
        if anomalies:
            for a in anomalies:
                print(f"ANOMALY: {a}")
        else:
            print("HEALTHY")
        for n in notes:
            print(f"NOTE: {n}")

    sys.exit(1 if anomalies else 0)


if __name__ == "__main__":
    main()
