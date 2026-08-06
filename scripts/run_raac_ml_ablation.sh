#!/usr/bin/env bash
# ML ablation for RAAC resubmission (JSS/JPDC "no ML ablation" critique).
#
# Runs ONLY the new "rule_based" arm (fixed payload-size threshold, no
# Isolation Forest) at n=8, using the exact same thresholds/occupancy bounds
# as "moderate" (see raac_arm_functions.sh) so the comparison is apples-to-
# apples with data already collected in the 20260726_100704_raac_full6arm
# run: static_besu (baseline), moderate_besu (ML-based RAAC). Adding this one
# new arm's n=8 reps to that existing static/moderate data gives the full
# three-way comparison without re-running static/moderate again.
#
# Arm: see scripts/raac_arm_functions.sh's "rule_based" case.
set -uo pipefail   # NOT -e: one failed rep must not abort the whole run
cd /home/yeochan.yoon/caliper-stress-test
source scripts/raac_arm_functions.sh
source scripts/resource_gate.sh

N_REPS="${N_REPS:-8}"
RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_ml_ablation"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_ml_ablation_run.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC ML ablation | rule_based arm | n=${N_REPS} | RUN_ID: ${RUN_ID}"
echo "  Heap=${HEAP_BESU}, workers=30 tps=100, 60+90+120+90+120+60=540s/rep"
echo "  Compare against static_besu / moderate_besu in"
echo "  results/raac_eval/20260726_100704_raac_full6arm/"
echo "======================================================================"

persistent_failures=0
MAX_PERSISTENT_FAILURES=3
circuit_broken=0

for i in $(seq 1 "${N_REPS}"); do
    [ "${circuit_broken}" -eq 1 ] && break
    wait_for_resource_headroom
    label="rule_based_besu_${i}"
    run_dir="${RESULTS_DIR}/${label}"
    attempt=1; max_attempts=3
    while true; do
        run_config "rule_based" "${i}"
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
            { echo "${label} (attempt ${attempt}/${max_attempts}):"; echo "${health_reason}"; echo; } >> "${RESULTS_DIR}/ANOMALOUS_RUNS.txt"
            persistent_failures=$((persistent_failures + 1))
            break
        fi
        echo "  WARNING: ${label} anomalous (attempt ${attempt}/${max_attempts}): ${health_reason}"
        echo "  Archiving bad attempt and retrying..."
        [ -d "${run_dir}" ] && mv "${run_dir}" "${run_dir}_BAD_attempt${attempt}_$(date +%H%M%S)"
        wait_for_resource_headroom
        sleep 20
        attempt=$((attempt + 1))
    done
    if [ "${persistent_failures}" -ge "${MAX_PERSISTENT_FAILURES}" ]; then
        echo "CIRCUIT BREAKER TRIPPED: ${persistent_failures} rule_based reps failed after ${max_attempts} attempts each -- stopping ML-ablation phase early."
        pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
        pkill -9 -f "serve\.py" 2>/dev/null || true
        fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
        {
            echo "ML-ablation phase CIRCUIT-BROKEN at $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Results dir: ${RESULTS_DIR}"
            echo "See ANOMALOUS_RUNS.txt for details. Needs diagnosis before re-running."
        } >> /home/yeochan.yoon/caliper-stress-test/NEEDS_ATTENTION_URGENT.txt
        circuit_broken=1
        break
    fi
    sleep 15
done

echo ""
echo "======================================================================"
echo "RAAC ML ablation COMPLETE — results in ${RESULTS_DIR}"
echo "======================================================================"

echo ""
echo "Symlinking existing static_besu/moderate_besu reps from the six-arm run"
echo "into this results dir, so bootstrap_ci_report.py (which only scans one"
echo "flat --results-dir) sees all three arms for a 3-way comparison..."
SIX_ARM_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260726_100704_raac_full6arm"
for d in "${SIX_ARM_DIR}"/static_besu_* "${SIX_ARM_DIR}"/moderate_besu_*; do
    [ -d "${d}" ] && ln -sfn "${d}" "${RESULTS_DIR}/$(basename "${d}")"
done

echo "Generating bootstrap-CI report (rule_based vs static/moderate)..."
python3.11 scripts/bootstrap_ci_report.py \
    --results-dir "${RESULTS_DIR}" \
    --baseline static_besu \
    --resamples 10000 --out "${RESULTS_DIR}/bootstrap_ci_report.md" \
    --out-json "${RESULTS_DIR}/bootstrap_ci_report.json"

echo "${RESULTS_DIR}" > /home/yeochan.yoon/caliper-stress-test/LATEST_ML_ABLATION_RESULTS_DIR.txt
echo "Done. Results dir recorded in LATEST_ML_ABLATION_RESULTS_DIR.txt"

echo ""
echo "Cleaning up temp/log clutter..."
rm -f /tmp/serve_ai_full6arm.log
: > /home/yeochan.yoon/caliper-stress-test/caliper.log 2>/dev/null || true
find /home/yeochan.yoon/caliper-stress-test -maxdepth 1 -name "data_n_*" -type d -exec rm -rf {} + 2>/dev/null || true
echo "Cleanup done."
