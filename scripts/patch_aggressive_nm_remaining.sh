#!/usr/bin/env bash
# Follow-up to watch_nm_rerun_then_patch_ulimit.sh, which patched 21/29
# contaminated combos (static x4, heap_only x8, dagor_nm_7, moderate x8)
# before being killed mid-run by systemd-logind reaping its `at`-job session
# (Linger=no for this account — fixed via `loginctl enable-linger
# yeochan.yoon` at 2026-07-23 ~13:53 KST, before this script was written).
# The 8 aggressive_nm reps were never reached and remain fd-exhaustion
# contaminated (515K-901K "Too many open files" occurrences each in
# ai_service_after.log). This script patches ONLY those 8 combos, then
# regenerates the bootstrap-CI report from the now-fully-patched results dir.
#
# Scheduled via `at 23:00` per the heavy-experiment-scheduling policy
# (daytime load from other teams' simv jobs makes idle_cores>25 unreliable
# during business hours; see resource_gate.sh header).
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

WATCH_LOG="/home/yeochan.yoon/caliper-stress-test/patch_aggressive_nm_remaining.log"
exec > >(tee -a "${WATCH_LOG}") 2>&1

echo ""
echo "======================================================================"
echo "patch_aggressive_nm_remaining started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260722_195217_raac_nm_full6arm"

if [ ! -d "${RESULTS_DIR}" ]; then
    echo "[$(date '+%H:%M:%S')] ABORT: expected RESULTS_DIR does not exist: ${RESULTS_DIR}"
    exit 1
fi

echo "[$(date '+%H:%M:%S')] Verifying no leftover pipeline processes..."
for i in $(seq 1 12); do
    still_running=0
    for pat in "hyperledger.besu.Besu" "nethermind.dll" "serve\.py"; do
        if pgrep -f "${pat}" > /dev/null 2>&1; then
            still_running=1
        fi
    done
    if [ "${still_running}" -eq 0 ]; then
        break
    fi
    echo "[$(date '+%H:%M:%S')] Leftover process(es) still exiting, waiting 10s (attempt ${i}/12)..."
    sleep 10
done
if pgrep -f "hyperledger.besu.Besu\|nethermind.dll\|serve\.py" > /dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] ABORT: pipeline processes still present after 2min grace — refusing to patch. Manual check needed."
    pgrep -af "hyperledger.besu.Besu\|nethermind.dll\|serve\.py"
    exit 1
fi

echo ""
echo "[$(date '+%H:%M:%S')] Re-scanning ${RESULTS_DIR} for fd-exhaustion contamination (sanity check)..."
CONTAMINATED=()
for cfg in static native_evict heap_only dagor moderate aggressive; do
    for rep in $(seq 1 8); do
        d="${RESULTS_DIR}/${cfg}_nm_${rep}"
        log="${d}/ai_service_after.log"
        if [ -f "${log}" ]; then
            cnt=$(grep -c "Too many open files" "${log}" 2>/dev/null); cnt=${cnt:-0}
            if [ "${cnt}" -gt 0 ] 2>/dev/null; then
                echo "  CONTAMINATED: ${cfg}_nm_${rep} (${cnt} EMFILE occurrences)"
                CONTAMINATED+=("${cfg} ${rep}")
            fi
        else
            echo "  MISSING ai_service_after.log: ${cfg}_nm_${rep} (treating as contaminated/incomplete)"
            CONTAMINATED+=("${cfg} ${rep}")
        fi
    done
done

echo ""
echo "[$(date '+%H:%M:%S')] ${#CONTAMINATED[@]} contaminated combo(s) found out of 48."
if [ "${#CONTAMINATED[@]}" -eq 0 ]; then
    echo "[$(date '+%H:%M:%S')] Nothing to patch. Done."
    exit 0
fi

export RESULTS_DIR
export RUN_ID="$(date +%Y%m%d_%H%M%S)_ulimit_patch2"
source scripts/raac_nm_arm_functions.sh
source scripts/resource_gate.sh

echo ""
echo "[$(date '+%H:%M:%S')] Re-running contaminated combos with ulimit-fixed launcher..."
for pair in "${CONTAMINATED[@]}"; do
    cfg="${pair% *}"; rep="${pair#* }"
    wait_for_resource_headroom
    run_config_nm "${cfg}" "${rep}"
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "  WARNING: ${cfg}_nm_${rep} patch-rerun failed (infra failure) — auto-retrying once"
        sleep 10
        run_config_nm "${cfg}" "${rep}" || echo "  WARNING: ${cfg}_nm_${rep} patch-rerun failed again, leaving prior (contaminated) data in place"
    fi
    sleep 15
done

echo ""
echo "[$(date '+%H:%M:%S')] Regenerating bootstrap-CI report from patched results dir..."
python3.11 scripts/bootstrap_ci_report.py --results-dir "${RESULTS_DIR}" --baseline static_nm \
    --resamples 10000 --out "${RESULTS_DIR}/bootstrap_ci_report.md" \
    --out-json "${RESULTS_DIR}/bootstrap_ci_report.json"

echo ""
echo "======================================================================"
echo "patch_aggressive_nm_remaining finished | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Patched ${#CONTAMINATED[@]} combo(s) in ${RESULTS_DIR}"
echo "======================================================================"
