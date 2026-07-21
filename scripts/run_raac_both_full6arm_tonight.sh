#!/usr/bin/env bash
# Tonight's (2026-07-21 23:00 KST) combined RAAC full 6-policy x n=8 run for
# BOTH Besu and NM, queued via `at` per AGENTS.md rule 1 (heavy experiments
# run at 23:00 KST, not during business hours) and rule 2 (no concurrent
# heavy jobs — pre-flight load/mem check below).
#
# Runs NM first (its NethDev->Clique+ServerGC migration + chainId fix was
# just validated via smoke test), then Besu (AI-service fail-open-under-load
# fix already validated earlier). Sequential only — they share ports
# 8545/8546/8000 (AGENTS.md rule 7).
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_both_full6arm_tonight.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC both-platform full 6-arm eval | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

# --- pre-flight: no leftover pipeline processes, load/mem sane ---
for pat in "hyperledger.besu.Besu" "nethermind.dll" "serve\.py" "run_raac_full_6arm.sh" "run_raac_nm_full_6arm.sh"; do
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
echo "Phase 1/2: NM full 6-arm (n=8)"
echo "=============================================="
bash scripts/run_raac_nm_full_6arm.sh
echo "NM phase exit code: $?"

echo ""
echo "Cooling down 60s between platforms..."
sleep 60

echo ""
echo "=============================================="
echo "Phase 2/2: Besu full 6-arm (n=8)"
echo "=============================================="
bash scripts/run_raac_full_6arm.sh
echo "Besu phase exit code: $?"

echo ""
echo "======================================================================"
echo "BOTH PLATFORMS COMPLETE | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  NM results dir:   $(cat LATEST_NM_FULL6ARM_RESULTS_DIR.txt 2>/dev/null || echo MISSING)"
echo "  Besu results dir: $(cat LATEST_FULL6ARM_RESULTS_DIR.txt 2>/dev/null || echo MISSING)"
echo "======================================================================"
