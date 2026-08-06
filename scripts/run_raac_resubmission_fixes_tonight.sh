#!/usr/bin/env bash
# Tonight's combined run for the two remaining JSS/JPDC resubmission fixes
# (queued via `at` for 23:00 KST per the heavy-experiment-scheduling policy
# -- no concurrent heavy jobs, pre-flight load/mem check below).
#
# 1. Fragmentation-evasion fix (quick, ~1 rep): corrected timing so the
#    fuzz-loop fires mid-steady-state-stress instead of after cool-down.
# 2. ML ablation (n=8): new "rule_based" arm, compared against the existing
#    static_besu/moderate_besu data already collected in the six-arm run.
#
# Sequential only -- both share ports 8545/8546/8000.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_resubmission_fixes_tonight.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC resubmission fixes (fragmentation + ML ablation) | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

# --- pre-flight: no leftover pipeline processes, load/mem sane ---
for pat in "hyperledger.besu.Besu" "nethermind.dll" "serve\.py" "run_raac_full_6arm.sh" "run_raac_nm_full_6arm.sh" "run_raac_ml_ablation.sh" "run_raac_fragmentation_fix.sh"; do
    if pgrep -f "${pat}" > /dev/null 2>&1; then
        echo "ABORT: found already-running process matching '${pat}' — refusing to start (would collide on shared ports)."
        pgrep -af "${pat}"
        exit 1
    fi
done

read -r load1 _ _ < /proc/loadavg
echo "Pre-flight: load1=${load1}"
free -h

echo ""
echo "=============================================="
echo "Phase 1/2: Fragmentation-evasion fix (1 rep)"
echo "=============================================="
bash scripts/run_raac_fragmentation_fix.sh
echo "Fragmentation-fix phase exit code: $?"

echo ""
echo "=============================================="
echo "Phase 2/2: ML ablation (rule_based, n=8)"
echo "=============================================="
bash scripts/run_raac_ml_ablation.sh
echo "ML-ablation phase exit code: $?"

echo ""
echo "======================================================================"
echo "Both phases complete. Results:"
echo "  Fragmentation: $(cat /home/yeochan.yoon/caliper-stress-test/LATEST_FRAGMENTATION_FIX_RESULTS_DIR.txt 2>/dev/null)"
echo "  ML ablation:   $(cat /home/yeochan.yoon/caliper-stress-test/LATEST_ML_ABLATION_RESULTS_DIR.txt 2>/dev/null)"
echo "======================================================================"
