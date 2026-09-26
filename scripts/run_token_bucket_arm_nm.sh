#!/usr/bin/env bash
# Token Bucket arm, n=8, Nethermind — mirrors run_token_bucket_arm_besu.sh.
# Runs from its own isolated execution copy so it can go fully in parallel
# with the Besu leg (the original NM script's "never run concurrently with
# Besu" warning was about both scripts sharing one physical directory/AI
# service port — not an issue here since Besu and NM each have their own
# execution copy on their own compute node).
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test-raac-r2-nm
export CALIPER_BASE_DIR="/home/yeochan.yoon/caliper-stress-test-raac-r2-nm"
source scripts/raac_nm_arm_functions.sh
source scripts/resource_gate.sh

N_REPS="${N_REPS:-8}"
ORIG_RUN_ID="20260802_004133_raac_nm_full6arm"
RUN_ID="${ORIG_RUN_ID}"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test-raac-r2-nm/results/raac_eval/${ORIG_RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test-raac-r2-nm/raac_tokenbucket_nm_run.log"

mkdir -p "$(dirname "${RESULTS_DIR}")"
if [ ! -d "${RESULTS_DIR}" ]; then
    echo "Copying original NM full6arm results dir (read-only source, shared checkout untouched)..."
    cp -r "/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${ORIG_RUN_ID}" "${RESULTS_DIR}"
fi

exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC Token Bucket arm (7th arm), Nethermind | n=${N_REPS} | into ${RESULTS_DIR}"
echo "======================================================================"

persistent_failures=0
MAX_PERSISTENT_FAILURES=3
circuit_broken=0

for i in $(seq 1 "${N_REPS}"); do
    [ "${circuit_broken}" -eq 1 ] && break
    wait_for_resource_headroom
    label="token_bucket_nm_${i}"
    run_dir="${RESULTS_DIR}/${label}"
    attempt=1; max_attempts=3
    while true; do
        run_config_nm "token_bucket" "${i}"
        rc=$?
        if [ $rc -ne 0 ]; then
            health_reason="infra_failure(rc=${rc})"; health_bad=1
        else
            health_output=$(python3.11 scripts/check_run_health.py "${run_dir}" 2>&1)
            if [ $? -eq 0 ]; then
                health_bad=0
            else
                health_reason="${health_output}"; health_bad=1
            fi
        fi
        if [ "${health_bad}" -eq 0 ]; then
            break
        fi
        if [ "${attempt}" -ge "${max_attempts}" ]; then
            echo "  WARNING: ${label} still anomalous after ${max_attempts} attempts -- keeping last attempt, flagging for review"
            { echo "${label} (attempt ${attempt}/${max_attempts}):"; echo "${health_reason}"; echo; } >> "${RESULTS_DIR}/ANOMALOUS_RUNS_TOKENBUCKET.txt"
            persistent_failures=$((persistent_failures + 1))
            break
        fi
        echo "  WARNING: ${label} anomalous (attempt ${attempt}/${max_attempts}): ${health_reason}"
        [ -d "${run_dir}" ] && mv "${run_dir}" "${run_dir}_BAD_attempt${attempt}_$(date +%H%M%S)"
        wait_for_resource_headroom
        sleep 20
        attempt=$((attempt + 1))
    done
    if [ "${persistent_failures}" -ge "${MAX_PERSISTENT_FAILURES}" ]; then
        echo "CIRCUIT BREAKER TRIPPED on Token Bucket NM arm — stopping, see ANOMALOUS_RUNS_TOKENBUCKET.txt"
        pkill -9 -f "nethermind.dll" 2>/dev/null || true
        pkill -9 -f "serve\.py" 2>/dev/null || true
        circuit_broken=1
        break
    fi
    sleep 15
done

echo ""
if [ "${circuit_broken}" -eq 1 ]; then
    echo "Token Bucket NM arm CIRCUIT-BROKEN — partial results in ${RESULTS_DIR}"
else
    echo "Token Bucket NM arm COMPLETE — results in ${RESULTS_DIR}"
fi

echo "Generating combined 7-arm bootstrap-CI report..."
python3.11 scripts/bootstrap_ci_report.py --results-dir "${RESULTS_DIR}" --baseline static_nm \
    --resamples 10000 --out "${RESULTS_DIR}/bootstrap_ci_report_7arm.md" \
    --out-json "${RESULTS_DIR}/bootstrap_ci_report_7arm.json"

echo "${RESULTS_DIR}" > /home/yeochan.yoon/caliper-stress-test-raac-r2-nm/LATEST_TOKENBUCKET_NM_RESULTS_DIR.txt
echo "Done."

if [ "${circuit_broken}" -eq 1 ]; then
    exit 2
fi
