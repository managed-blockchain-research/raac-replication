#!/usr/bin/env bash
# RAAC Besu 5-arm evaluation at heap=8g WITH ATTACK INTENSITY SCALED 8x
# (RAAC_TARGET_TPS=800, up from the default 100) -- validates that the
# muted effect observed at 8GB with the DEFAULT (1x) attack intensity
# (scripts/run_raac_besu_8g_6arm.sh) is a property of attack-severity-
# relative-to-heap, not of heap size in isolation. At 1GB, the fixed
# ~1.15GB/120s attack burst is ~115% of heap; at 8GB with the same 1x
# intensity it is only ~14%. Scaling RAAC_TARGET_TPS 8x (100->800) delivers
# ~8x the attack byte-volume in the same 120s attack-round window,
# reconstructing approximately the same ~115% severity-to-heap ratio at
# 8GB that was originally observed at 1GB. If RAAC's own mechanisms
# (Moderate/Aggressive) recover a large duty-cycle reduction here despite
# the generous 8GB heap, that confirms RAAC's usefulness tracks relative
# attack severity, not absolute heap size -- i.e. it remains valuable
# against a sufficiently severe/adaptive attacker even on a
# recommended-sized, generously-provisioned node. We scale TPS rather than
# per-transaction payload size specifically to avoid confounding with
# G1GC's heap-size-dependent humongous-object region-size heuristic, and
# rather than round duration specifically to avoid an ~8x wall-clock blowup.
# RAAC_TARGET_TPS is read once via env var by mixedAttackLOHRaacBurst.js
# (already-existing knob, zero code changes) and applies uniformly across
# calm and attack rounds alike -- calm rounds simply carry 8x more
# legitimate traffic.
#
# native_evict EXCLUDED from this sweep (smoke test 20260805_071745): its
# tx_pool_max_prioritized=64 was deliberately tuned tiny for RAAC_TARGET_TPS=100
# (see raac_arm_functions.sh:123-206). At TPS=800 the same 64-slot pool takes
# 8x the submission pressure, causing pool-eviction storms severe enough that
# Besu's own Netty RPC acceptor thread started throwing
# "Failed to register an accepted channel" / IllegalStateException, at which
# point Succ froze while Fail climbed unbounded (~98% fail, still climbing,
# in attack-burst-1 of the smoke test). This is a known, already-documented
# scaling limit of native_evict's tiny-pool design, not a new finding
# relevant to this experiment's question (whether RAAC's OWN adaptive
# policies -- Moderate/Aggressive -- regain benefit at 8GB under
# proportionally severe attack). Re-tuning native_evict's pool size to scale
# with TPS would confound the "keep native_evict's definition constant
# across the heap/severity sweep" comparison anyway, so it is simply out of
# scope here rather than fixed.
#
# Arms: static heap_only dagor moderate aggressive (see
# scripts/raac_arm_functions.sh, shared library).
#
# After the LAST aggressive rep's caliper run (steady-state-stress phase has
# already lowered the threshold), the fragmentation fuzz-loop runs against
# the still-live node before teardown.
set -uo pipefail   # NOT -e: one failed rep must not abort the whole night
cd /home/yeochan.yoon/caliper-stress-test
export HEAP_BESU_OVERRIDE="8g"
export RAAC_TARGET_TPS="${RAAC_TARGET_TPS:-800}"
source scripts/raac_arm_functions.sh
source scripts/resource_gate.sh

# n=8: 5 arms x 8 reps x ~630s/rep (incl. teardown/overhead) ~= 7h, leaving
# buffer before "morning" for a possible re-run of one arm plus the paper
# rewrite.
N_REPS="${N_REPS:-8}"
RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_besu8g_scaledattack_5arm"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_besu8g_scaledattack_5arm_run.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC Besu 5-arm eval @ 8GB heap, 8x SCALED ATTACK (RAAC_TARGET_TPS=${RAAC_TARGET_TPS}) | n=${N_REPS} each | RUN_ID: ${RUN_ID}"
echo "  Arms: static heap_only dagor moderate aggressive (native_evict excluded -- see header comment)"
echo "  Heap=${HEAP_BESU}, workers=30 tps=${RAAC_TARGET_TPS}, 60+90+120+90+120+60=540s/rep"
echo "======================================================================"

echo ""
echo "=============================="
echo "Starting full 5-arm eval: 5 x ${N_REPS} = $((5 * N_REPS)) runs"
echo "=============================="


# Circuit breaker: a single anomalous run after 3 attempts might just be bad
# luck (host contention). THREE separate labels each exhausting their
# attempts is a different kind of signal -- a systemic/design problem (like
# 2026-07-31's nonce race or maxSockets mismatch), where keeping retrying the
# SAME config the rest of the night just burns hours producing more of the
# same bad data. Stop the phase, tear down cleanly, and flag loudly instead --
# no one is here to redesign it interactively over the weekend, but a script
# grinding through 48 reps of a known-broken config is worse than stopping
# and waiting for a human/Claude to look at NEEDS_ATTENTION_URGENT.txt.
persistent_failures=0
MAX_PERSISTENT_FAILURES=3
circuit_broken=0

for i in $(seq 1 "${N_REPS}"); do
    [ "${circuit_broken}" -eq 1 ] && break
    for cfg in static heap_only dagor moderate aggressive; do
        wait_for_resource_headroom
        label="${cfg}_besu_${i}"
        run_dir="${RESULTS_DIR}/${label}"
        attempt=1; max_attempts=3
        while true; do
            run_config "${cfg}" "${i}"
            rc=$?
            if [ $rc -ne 0 ]; then
                health_reason="infra_failure(rc=${rc})"; health_bad=1
            else
                # Quality check: run_config's `wait $caliper_pid || true` means a
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
            echo "the Besu 5-arm phase here (not blindly running the remaining reps)."
            echo "######################################################################"
            pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
            pkill -9 -f "serve\.py" 2>/dev/null || true
            fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
            {
                echo "Besu 6-arm phase CIRCUIT-BROKEN at $(date '+%Y-%m-%d %H:%M:%S')"
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
    echo "RAAC Besu 8GB scaled-attack 5-arm eval CIRCUIT-BROKEN (stopped early) — partial results in ${RESULTS_DIR}"
else
    echo "RAAC Besu 8GB scaled-attack 5-arm eval COMPLETE — results in ${RESULTS_DIR}"
fi
echo "======================================================================"

echo ""
echo "Generating bootstrap-CI report (whatever completed so far)..."
python3.11 scripts/bootstrap_ci_report.py --results-dir "${RESULTS_DIR}" --baseline static_besu \
    --resamples 10000 --out "${RESULTS_DIR}/bootstrap_ci_report.md" \
    --out-json "${RESULTS_DIR}/bootstrap_ci_report.json"

echo "${RESULTS_DIR}" > /home/yeochan.yoon/caliper-stress-test/LATEST_BESU8G_SCALEDATTACK_5ARM_RESULTS_DIR.txt
echo "Done. Results dir recorded in LATEST_BESU8G_SCALEDATTACK_5ARM_RESULTS_DIR.txt (kept separate from the 4GB/1GB/8GB-default-intensity pointer files)."

echo ""
echo "Cleaning up temp/log clutter..."
rm -f /tmp/serve_ai_full6arm.log
: > /home/yeochan.yoon/caliper-stress-test/caliper.log 2>/dev/null || true
find /home/yeochan.yoon/caliper-stress-test -maxdepth 1 -name "data_n_*" -type d -exec rm -rf {} + 2>/dev/null || true
echo "Cleanup done."

if [ "${circuit_broken}" -eq 1 ]; then
    exit 2
fi
