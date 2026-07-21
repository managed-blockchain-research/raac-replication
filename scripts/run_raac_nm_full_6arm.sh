#!/usr/bin/env bash
# RAAC NM (Nethermind) full 6-arm evaluation — companion to
# run_raac_full_6arm.sh (Besu). Same 6 arms, adapted to .NET specifics (see
# raac_nm_arm_functions.sh). Never run concurrently with the Besu script —
# they share ports 8545/8546/8000 and will corrupt each other's runs
# (AGENTS.md item 7).
#
# Consensus: Clique PoA (not NethDev — NethDev has a hard 5-tx/block ceiling
# that caused a 99.98% FeeTooLowToCompete failure rate under attack load).
# GC: Server GC (DOTNET_gcServer=1, not Workstation) for better scaling under
# the 30-worker concurrent load. See raac_nm_arm_functions.sh for the launch
# flags and raac_clique_nm.json for the chainspec (chainId 0x63 to match
# Caliper's networkconfig — this mismatch was the second half of the fix).
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test
source scripts/raac_nm_arm_functions.sh

N_REPS="${N_REPS:-8}"
RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_nm_full6arm"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_nm_full6arm_run.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC NM full 6-arm eval | n=${N_REPS} each | RUN_ID: ${RUN_ID}"
echo "  Arms: static arm0 heap_only dagor moderate aggressive"
echo "  Heap=4GB (DOTNET_GCHeapHardLimit), Server GC, Clique PoA, RSS-based pressure"
echo "======================================================================"

echo ""
echo "=============================="
echo "Starting NM full 6-arm eval: 6 x ${N_REPS} = $((6 * N_REPS)) runs"
echo "=============================="

for i in $(seq 1 "${N_REPS}"); do
    for cfg in static arm0 heap_only dagor moderate aggressive; do
        run_config_nm "${cfg}" "${i}"
        rc=$?
        if [ $rc -ne 0 ]; then
            echo "  WARNING: ${cfg}_nm_${i} failed (infra failure) — auto-retrying once"
            sleep 10
            run_config_nm "${cfg}" "${i}" || echo "  WARNING: ${cfg}_nm_${i} failed again, continuing without it"
        fi
        sleep 15
    done
done

echo ""
echo "======================================================================"
echo "RAAC NM full 6-arm eval COMPLETE — results in ${RESULTS_DIR}"
echo "======================================================================"

echo ""
echo "Generating bootstrap-CI report..."
python3.11 scripts/bootstrap_ci_report.py --results-dir "${RESULTS_DIR}" --baseline static_nm \
    --resamples 10000 --out "${RESULTS_DIR}/bootstrap_ci_report.md" \
    --out-json "${RESULTS_DIR}/bootstrap_ci_report.json"

echo "${RESULTS_DIR}" > /home/yeochan.yoon/caliper-stress-test/LATEST_NM_FULL6ARM_RESULTS_DIR.txt
echo "Done. Results dir recorded in LATEST_NM_FULL6ARM_RESULTS_DIR.txt"

echo ""
echo "Cleaning up temp/log clutter..."
rm -f /tmp/serve_ai_nm_full6arm.log
: > /home/yeochan.yoon/caliper-stress-test/caliper.log 2>/dev/null || true
find /home/yeochan.yoon/caliper-stress-test -maxdepth 1 -name "data_n_*" -type d -exec rm -rf {} + 2>/dev/null || true
echo "Cleanup done."
