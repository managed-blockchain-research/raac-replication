#!/usr/bin/env bash
# RAAC full 6-arm evaluation for resubmission — static / arm0 / heap_only /
# dagor / moderate / aggressive, n=8 each (up from n=3 in the original
# eval13), full scale (workers=30, tps=100, heap=1g, 540s/rep) matching the
# calibrated thresholds documented in run_raac_besu_eval13.sh.
#
# Arms: see scripts/raac_arm_functions.sh (shared library, also used by
# scripts/rerun_single_run.sh for targeted re-runs of one arm/rep found bad
# during a mid-run sanity check, instead of re-running the whole night).
#
# After the LAST aggressive rep's caliper run (steady-state-stress phase has
# already lowered the threshold), the fragmentation fuzz-loop runs against
# the still-live node before teardown.
set -uo pipefail   # NOT -e: one failed rep must not abort the whole night
cd /home/yeochan.yoon/caliper-stress-test
source scripts/raac_arm_functions.sh
source scripts/resource_gate.sh

# n=8: 6 arms x 8 reps x ~630s/rep (incl. teardown/overhead) ~= 8.4h, leaving
# buffer before "morning" for a possible re-run of one arm plus the paper
# rewrite. n=10 would run ~10.5h and cut the buffer too close.
N_REPS="${N_REPS:-8}"
RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_full6arm"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_full6arm_run.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC full 6-arm eval | n=${N_REPS} each | RUN_ID: ${RUN_ID}"
echo "  Arms: static arm0 heap_only dagor moderate aggressive"
echo "  Heap=${HEAP_BESU}, workers=30 tps=100, 60+90+120+90+120+60=540s/rep"
echo "======================================================================"

echo ""
echo "=============================="
echo "Starting full 6-arm eval: 6 x ${N_REPS} = $((6 * N_REPS)) runs"
echo "=============================="

for i in $(seq 1 "${N_REPS}"); do
    for cfg in static arm0 heap_only dagor moderate aggressive; do
        wait_for_resource_headroom
        run_config "${cfg}" "${i}"
        rc=$?
        if [ $rc -ne 0 ]; then
            echo "  WARNING: ${cfg}_besu_${i} failed (infra failure) — auto-retrying once"
            sleep 10
            run_config "${cfg}" "${i}" || echo "  WARNING: ${cfg}_besu_${i} failed again, continuing without it"
        fi
        sleep 15
    done
done

echo ""
echo "======================================================================"
echo "RAAC full 6-arm eval COMPLETE — results in ${RESULTS_DIR}"
echo "======================================================================"

echo ""
echo "Generating bootstrap-CI report..."
python3.11 scripts/bootstrap_ci_report.py --results-dir "${RESULTS_DIR}" --baseline static_besu \
    --resamples 10000 --out "${RESULTS_DIR}/bootstrap_ci_report.md" \
    --out-json "${RESULTS_DIR}/bootstrap_ci_report.json"

echo "${RESULTS_DIR}" > /home/yeochan.yoon/caliper-stress-test/LATEST_FULL6ARM_RESULTS_DIR.txt
echo "Done. Results dir recorded in LATEST_FULL6ARM_RESULTS_DIR.txt"

echo ""
echo "Cleaning up temp/log clutter..."
rm -f /tmp/serve_ai_full6arm.log
: > /home/yeochan.yoon/caliper-stress-test/caliper.log 2>/dev/null || true
find /home/yeochan.yoon/caliper-stress-test -maxdepth 1 -name "data_n_*" -type d -exec rm -rf {} + 2>/dev/null || true
echo "Cleanup done."
