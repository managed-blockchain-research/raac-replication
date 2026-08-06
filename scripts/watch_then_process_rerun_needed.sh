#!/usr/bin/env bash
# Waits for job32 (run_raac_both_full6arm_tonight.sh, RUN_ID
# 20260723_141401_raac_nm_full6arm for NM) to fully finish both platforms,
# then processes RERUN_NEEDED.txt: re-runs each flagged (policy, rep) combo
# individually via resource_gate.sh's real-time load check (not a fixed
# clock time — the actual protection is the load measurement, clock time is
# just a heuristic proxy for it), then regenerates the NM bootstrap-CI
# report. Leaves Besu's RERUN_NEEDED handling for a future pass (none
# flagged yet as of this script's creation).
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

WATCH_LOG="/home/yeochan.yoon/caliper-stress-test/watch_then_process_rerun_needed.log"
exec > >(tee -a "${WATCH_LOG}") 2>&1

echo ""
echo "======================================================================"
echo "watch_then_process_rerun_needed started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

TONIGHT_LOG="/home/yeochan.yoon/caliper-stress-test/raac_both_full6arm_tonight.log"
# This log is append-only across every past invocation of this wrapper —
# gate on this specific job's RUN_ID appearing in the completion banner,
# not just any "BOTH PLATFORMS COMPLETE" string (see AGENTS.md rule 14).
NM_RUN_ID="20260723_141401_raac_nm_full6arm"

while true; do
    if grep -q "BOTH PLATFORMS COMPLETE" "${TONIGHT_LOG}" 2>/dev/null && \
       grep -A3 "BOTH PLATFORMS COMPLETE" "${TONIGHT_LOG}" 2>/dev/null | tail -20 | grep -q "${NM_RUN_ID}"; then
        echo "[$(date '+%H:%M:%S')] Detected BOTH PLATFORMS COMPLETE for ${NM_RUN_ID}."
        break
    fi
    echo "[$(date '+%H:%M:%S')] job32 still running, waiting 300s..."
    sleep 300
done

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
    echo "[$(date '+%H:%M:%S')] ABORT: pipeline processes still present after 2min grace — refusing to start."
    pgrep -af "hyperledger.besu.Besu\|nethermind.dll\|serve\.py"
    exit 1
fi

RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${NM_RUN_ID}"
if [ ! -d "${RESULTS_DIR}" ]; then
    echo "[$(date '+%H:%M:%S')] ABORT: expected RESULTS_DIR does not exist: ${RESULTS_DIR}"
    exit 1
fi

echo "[$(date '+%H:%M:%S')] Parsing RERUN_NEEDED.txt for NM entries against ${NM_RUN_ID}..."
export RESULTS_DIR
export RUN_ID="$(date +%Y%m%d_%H%M%S)_rerun_needed_patch"
source scripts/raac_nm_arm_functions.sh
source scripts/resource_gate.sh

found=0
while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    read -r cfg_platform rep run_id_field _ <<< "$line"
    platform="${cfg_platform##*_}"
    cfg="${cfg_platform%_*}"
    [ "${platform}" != "nm" ] && continue
    [ "${run_id_field}" != "${NM_RUN_ID}" ] && continue
    found=1
    echo "[$(date '+%H:%M:%S')] Re-running ${cfg}_nm_${rep} (waiting for real resource headroom, not a fixed clock time)..."
    wait_for_resource_headroom
    run_config_nm "${cfg}" "${rep}"
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "  WARNING: ${cfg}_nm_${rep} failed — auto-retrying once"
        sleep 10
        run_config_nm "${cfg}" "${rep}" || echo "  WARNING: ${cfg}_nm_${rep} failed again, leaving prior data in place"
    fi
    sleep 15
done < RERUN_NEEDED.txt

if [ "${found}" -eq 0 ]; then
    echo "[$(date '+%H:%M:%S')] No NM entries found for ${NM_RUN_ID} in RERUN_NEEDED.txt. Nothing to do."
    exit 0
fi

echo ""
echo "[$(date '+%H:%M:%S')] Regenerating bootstrap-CI report..."
python3.11 scripts/bootstrap_ci_report.py --results-dir "${RESULTS_DIR}" --baseline static_nm \
    --resamples 10000 --out "${RESULTS_DIR}/bootstrap_ci_report.md" \
    --out-json "${RESULTS_DIR}/bootstrap_ci_report.json"

echo ""
echo "======================================================================"
echo "watch_then_process_rerun_needed finished | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"
