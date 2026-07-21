#!/usr/bin/env bash
# Re-run exactly one arm/rep into an EXISTING results directory, e.g. after a
# mid-run sanity check finds one run's numbers look wrong (not a hard crash,
# just suspicious) and decides to redo it — instead of restarting the whole
# 6-arm x n=8 night from scratch.
#
# Usage:
#   bash rerun_single_run.sh <RESULTS_DIR> <config> <rep> [occu_low occu_high heap_only_cutoff dagor_cpu_low dagor_cpu_high]
#
# Example — redo dagor rep 3 with recalibrated CPU bounds after observing the
# real Besu CPU% during tonight's run didn't match the original 100-800 guess:
#   bash rerun_single_run.sh /path/to/results/raac_eval/20260720_XXXXXX_raac_full6arm \
#       dagor 3 "" "" "" 150 600
#
# Pass "" for any positional override you don't want to change (keeps the
# arm's calibrated default from raac_arm_functions.sh).
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test
source scripts/raac_arm_functions.sh

RESULTS_DIR="${1:?Usage: rerun_single_run.sh <RESULTS_DIR> <config> <rep> [occu_low occu_high heap_only_cutoff dagor_cpu_low dagor_cpu_high]}"
CONFIG="${2:?config required (static|native_evict|heap_only|dagor|moderate|aggressive)}"
REP="${3:?rep number required}"
OVERRIDE_OCCU_LOW="${4:-}"
OVERRIDE_OCCU_HIGH="${5:-}"
OVERRIDE_CUTOFF="${6:-}"
OVERRIDE_DAGOR_LOW="${7:-}"
OVERRIDE_DAGOR_HIGH="${8:-}"

RUN_ID="$(basename "${RESULTS_DIR}")"
N_REPS="${N_REPS:-8}"   # only affects whether the fragmentation hook fires (aggressive + last rep)

LOG_FILE="/home/yeochan.yoon/caliper-stress-test/rerun_${CONFIG}_${REP}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "======================================================================"
echo "Targeted re-run: ${CONFIG}_besu_${REP} into ${RESULTS_DIR}"
echo "  overrides: occu=[${OVERRIDE_OCCU_LOW:-default},${OVERRIDE_OCCU_HIGH:-default}] cutoff=${OVERRIDE_CUTOFF:-default} dagor_cpu=[${OVERRIDE_DAGOR_LOW:-default},${OVERRIDE_DAGOR_HIGH:-default}]"
echo "======================================================================"

if [ ! -d "${RESULTS_DIR}" ]; then
    echo "ERROR: results dir ${RESULTS_DIR} does not exist"; exit 1
fi

# Move the old (bad) run dir aside instead of overwriting silently.
old_dir="${RESULTS_DIR}/${CONFIG}_besu_${REP}"
if [ -d "${old_dir}" ]; then
    mv "${old_dir}" "${old_dir}_SUPERSEDED_$(date +%H%M%S)"
fi

run_config "${CONFIG}" "${REP}" "${OVERRIDE_OCCU_LOW}" "${OVERRIDE_OCCU_HIGH}" "${OVERRIDE_CUTOFF}" "${OVERRIDE_DAGOR_LOW}" "${OVERRIDE_DAGOR_HIGH}"
rc=$?

if [ $rc -eq 0 ]; then
    echo "Re-run of ${CONFIG}_besu_${REP} succeeded."
else
    echo "Re-run of ${CONFIG}_besu_${REP} FAILED again (rc=${rc}) — check ${old_dir%/*}/${CONFIG}_besu_${REP}/FAILED and besu_console.log"
fi

# Refresh the bootstrap-CI report so it reflects the corrected run.
python3.11 scripts/bootstrap_ci_report.py --results-dir "${RESULTS_DIR}" --baseline static_besu \
    --resamples 10000 --out "${RESULTS_DIR}/bootstrap_ci_report.md" \
    --out-json "${RESULTS_DIR}/bootstrap_ci_report.json"

exit $rc
