#!/bin/bash
# Chain: RACE NM (AuRa flood) → RACE Besu → RAAC eval
LOG="/tmp/chain_race_raac.log"
RACE_NM_SCRIPT="/home/yeochan.yoon/caliper-stress-test/scripts/run_race_nm_eval.sh"
RACE_BESU_SCRIPT="/home/yeochan.yoon/caliper-stress-test/scripts/run_race_besu_eval.sh"
RAAC_SCRIPT="/home/yeochan.yoon/caliper-stress-test/scripts/run_raac_eval.sh"

echo "[$(date)] Starting RACE NM (AuRa flood design)..." | tee -a "${LOG}"
bash "${RACE_NM_SCRIPT}" >> "${LOG}" 2>&1
echo "[$(date)] RACE NM complete. Starting RACE Besu..." | tee -a "${LOG}"
bash "${RACE_BESU_SCRIPT}" >> "${LOG}" 2>&1
echo "[$(date)] RACE Besu complete. Starting RAAC eval..." | tee -a "${LOG}"
bash "${RAAC_SCRIPT}" >> "${LOG}" 2>&1
echo "[$(date)] All done." | tee -a "${LOG}"
