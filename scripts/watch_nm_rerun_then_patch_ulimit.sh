#!/usr/bin/env bash
# Waits for the currently-running fixed-serve.py NM rerun
# (results/raac_eval/20260722_195217_raac_nm_full6arm) to finish all 8 reps,
# then scans every (policy, rep) run in it for AI-service fd-exhaustion
# contamination ("Too many open files" — see raac_nm_round3_stall_bug memory,
# 2026-07-22 ~21:00-21:40 KST update) and re-runs ONLY the contaminated
# combos using the now-ulimit-fixed launcher (raac_nm_arm_functions.sh /
# raac_arm_functions.sh, both patched with `ulimit -n 65536` before serve.py
# starts). Clean combos are left untouched. Bootstrap CI report is
# regenerated afterward from the patched-in-place results dir.
#
# User explicitly chose this targeted-repair approach over a full 3rd
# 8x6 rerun (2026-07-22 ~21:45 KST): much cheaper, and the ulimit fix is a
# pure infra correction (doesn't touch admission-control logic/thresholds),
# so swapping in re-run data for just the contaminated slots is valid.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

WATCH_LOG="/home/yeochan.yoon/caliper-stress-test/watch_nm_rerun_then_patch_ulimit.log"
exec > >(tee -a "${WATCH_LOG}") 2>&1

echo ""
echo "======================================================================"
echo "watch_nm_rerun_then_patch_ulimit started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

POLL_INTERVAL=300  # 5 min
# Hardcoded to THIS specific rerun's known RUN_ID (started 2026-07-22
# 19:52:17 after Besu completed) rather than grepping raac_nm_full6arm_run.log
# or trusting LATEST_NM_FULL6ARM_RESULTS_DIR.txt — both are shared/append-only
# across every past invocation (including last night's now-invalid run), so a
# naive "COMPLETE" log-grep or pointer-file read can match stale history from
# a run that already finished hours ago. bootstrap_ci_report.md existing
# specifically inside THIS dir is only ever written once, at the very end of
# this exact run_raac_nm_full_6arm.sh invocation.
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260722_195217_raac_nm_full6arm"

while true; do
    if [ -f "${RESULTS_DIR}/bootstrap_ci_report.md" ] \
        && ! pgrep -f "nethermind.dll" > /dev/null 2>&1 \
        && ! pgrep -f "run_raac_nm_full_6arm.sh" > /dev/null 2>&1; then
        echo "[$(date '+%H:%M:%S')] Detected THIS run's bootstrap_ci_report.md + no active NM process/script — rerun complete."
        break
    fi
    echo "[$(date '+%H:%M:%S')] NM rerun still in progress, waiting ${POLL_INTERVAL}s..."
    sleep "${POLL_INTERVAL}"
done

# Extra grace for any trailing cleanup in run_raac_nm_full_6arm.sh.
sleep 20

if [ ! -d "${RESULTS_DIR}" ]; then
    echo "[$(date '+%H:%M:%S')] ABORT: expected RESULTS_DIR does not exist: ${RESULTS_DIR}"
    exit 1
fi
echo "[$(date '+%H:%M:%S')] RESULTS_DIR=${RESULTS_DIR}"

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
echo "[$(date '+%H:%M:%S')] Scanning ${RESULTS_DIR} for fd-exhaustion contamination..."
CONTAMINATED=()
for cfg in static native_evict heap_only dagor moderate aggressive; do
    for rep in $(seq 1 8); do
        d="${RESULTS_DIR}/${cfg}_nm_${rep}"
        log="${d}/ai_service_after.log"
        if [ -f "${log}" ]; then
            cnt=$(grep -c "Too many open files" "${log}" 2>/dev/null || echo 0)
            if [ "${cnt}" -gt 0 ]; then
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
export RUN_ID="$(date +%Y%m%d_%H%M%S)_ulimit_patch"
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
echo "watch_nm_rerun_then_patch_ulimit finished | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Patched ${#CONTAMINATED[@]} combo(s) in ${RESULTS_DIR}"
echo "======================================================================"
