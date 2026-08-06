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
source scripts/resource_gate.sh

N_REPS="${N_REPS:-8}"
RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_nm_full6arm"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_nm_full6arm_run.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC NM full 6-arm eval | n=${N_REPS} each | RUN_ID: ${RUN_ID}"
echo "  Arms: static native_evict heap_only dagor moderate aggressive"
echo "  Heap=4GB (DOTNET_GCHeapHardLimit), Server GC, Clique PoA, RSS-based pressure"
echo "======================================================================"

echo ""
echo "=============================="
echo "Starting NM full 6-arm eval: 6 x ${N_REPS} = $((6 * N_REPS)) runs"
echo "=============================="


# Circuit breaker: see run_raac_full_6arm.sh (Besu) for the full rationale --
# one anomalous label after retries might be host-contention noise, but three
# separate labels each exhausting their attempts signals a systemic/design
# problem worth stopping for rather than grinding through the remaining reps.
persistent_failures=0
MAX_PERSISTENT_FAILURES=3
circuit_broken=0

for i in $(seq 1 "${N_REPS}"); do
    [ "${circuit_broken}" -eq 1 ] && break
    for cfg in static native_evict heap_only dagor moderate aggressive; do
        wait_for_resource_headroom
        label="${cfg}_nm_${i}"
        run_dir="${RESULTS_DIR}/${label}"
        attempt=1; max_attempts=3
        while true; do
            run_config_nm "${cfg}" "${i}"
            rc=$?
            if [ $rc -ne 0 ]; then
                health_reason="infra_failure(rc=${rc})"; health_bad=1
            else
                # Quality check: run_config_nm's `wait $caliper_pid || true` means a
                # timed-out/hung caliper run still returns rc=0 -- this catches
                # what the rc check above cannot (see check_run_health.py header).
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
            echo ""
            echo "######################################################################"
            echo "CIRCUIT BREAKER TRIPPED: ${persistent_failures} labels failed after ${max_attempts} attempts each."
            echo "Suspecting a systemic/design issue, not host-contention noise. Stopping"
            echo "the NM 6-arm phase here (not blindly running the remaining reps)."
            echo "######################################################################"
            pkill -9 -f "nethermind.dll" 2>/dev/null || true
            pkill -9 -f "serve\.py" 2>/dev/null || true
            fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
            {
                echo "NM 6-arm phase CIRCUIT-BROKEN at $(date '+%Y-%m-%d %H:%M:%S')"
                echo "Results dir: ${RESULTS_DIR}"
                echo "See ANOMALOUS_RUNS.txt in that directory for details on each failed label."
                echo "Needs a human/Claude to diagnose root cause and redesign before re-running this phase."
            } >> /home/yeochan.yoon/caliper-stress-test/NEEDS_ATTENTION_URGENT.txt
            circuit_broken=1
            break
        fi
        sleep 15
    done
done

echo ""
echo "======================================================================"
if [ "${circuit_broken}" -eq 1 ]; then
    echo "RAAC NM full 6-arm eval CIRCUIT-BROKEN (stopped early) — partial results in ${RESULTS_DIR}"
else
    echo "RAAC NM full 6-arm eval COMPLETE — results in ${RESULTS_DIR}"
fi
echo "======================================================================"

echo ""
echo "Generating bootstrap-CI report (whatever completed so far)..."
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

if [ "${circuit_broken}" -eq 1 ]; then
    exit 2
fi
