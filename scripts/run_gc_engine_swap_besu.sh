#!/usr/bin/env bash
# GC-engine-swap experiment (2026-09-24 ETRI resubmission pass), Besu leg.
# Flags-only: same static/native_evict admission configs, same workload,
# just G1GC vs ZGC. Tests whether native-pool-bounding's Besu dominance
# (Section "Cross-Runtime GC Duty-Cycle Reduction": Native Evict -41.6% at
# 4GB) is really a GC-DESIGN inversion (compacting/regional G1 vs
# pauseless/concurrent ZGC), not a Besu-vs-Nethermind platform inversion --
# prior PALS-paper experiments in this project found ZGC/Shenandoah
# near-pause-free regardless of configuration; if that holds here too,
# native-pool-bounding's advantage over Static should collapse under ZGC
# (nothing left for a smaller pool to work around).
#
# n=3 pilot (not n=8): this is a directional check to decide whether the
# full framing needs revising before spending the much larger n=8 budget on
# it, matching this paper's existing precedent for a small-n pilot ahead of
# a statistically rigorous follow-up (see "Detection Performance and
# Overhead" section's n=3 Besu pilot).
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test-raac-r2-gcswap
export CALIPER_BASE_DIR="/home/yeochan.yoon/caliper-stress-test-raac-r2-gcswap"
source scripts/raac_arm_functions.sh
source scripts/resource_gate.sh

N_REPS="${N_REPS:-3}"
RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_gcswap"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test-raac-r2-gcswap/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test-raac-r2-gcswap/raac_gcswap_run.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC GC-engine-swap pilot | n=${N_REPS} each | RUN_ID: ${RUN_ID}"
echo "  Pairs: static+native_evict x {g1,zgc}"
echo "======================================================================"

for pair in "static:g1" "static:zgc" "native_evict:g1" "native_evict:zgc"; do
    cfg="${pair%%:*}"; engine="${pair##*:}"
    export GC_ENGINE="${engine}"
    label_suffix="${cfg}_${engine}"
    for i in $(seq 1 "${N_REPS}"); do
        wait_for_resource_headroom
        # run_config always names the dir "<config>_besu_<rep>" -- rename
        # after each call to keep g1/zgc runs from colliding, since GC_ENGINE
        # isn't part of run_config's own naming scheme.
        run_config "${cfg}" "${i}"
        rc=$?
        src_dir="${RESULTS_DIR}/${cfg}_besu_${i}"
        dst_dir="${RESULTS_DIR}/${label_suffix}_besu_${i}"
        [ -d "${src_dir}" ] && mv "${src_dir}" "${dst_dir}"
        if [ $rc -ne 0 ]; then
            echo "  WARNING: ${label_suffix}_besu_${i} failed (rc=${rc})"
        else
            health_output=$(python3.11 scripts/check_run_health.py "${dst_dir}" 2>&1) || \
                echo "  WARNING: ${label_suffix}_besu_${i} anomalous: ${health_output}"
        fi
        sleep 15
    done
done
unset GC_ENGINE

echo ""
echo "GC-engine-swap pilot COMPLETE — results in ${RESULTS_DIR}"
echo "Per-label GC totals (see gc_summary.txt in each run dir):"
for d in "${RESULTS_DIR}"/*_besu_*/; do
    [ -f "${d}gc_summary.txt" ] && echo "  $(basename "${d}"): $(cat "${d}gc_summary.txt") ms"
done

echo "${RESULTS_DIR}" > /home/yeochan.yoon/caliper-stress-test-raac-r2-gcswap/LATEST_GCSWAP_RESULTS_DIR.txt
echo "Done."
