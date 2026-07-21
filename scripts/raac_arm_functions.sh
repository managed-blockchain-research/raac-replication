#!/usr/bin/env bash
# Shared functions/config for RAAC 6-arm eval runs. Sourced by both
# run_raac_full_6arm.sh (the full night's loop) and rerun_single_run.sh
# (targeted re-run of one arm/rep, e.g. after a mid-run sanity check flags
# something wrong). Keeping this in one place means a fix here (like the
# taskset/OOM lessons already learned) applies to both automatically.
#
# Callers must set: RESULTS_DIR, RUN_ID, N_REPS (N_REPS only matters for the
# fragmentation-fuzz hook's "last aggressive rep" check) before calling
# run_config.

BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
HEAP_BESU="1g"
NETWORKCONFIG_BESU="networkconfig.json"
DEPLOY_BESU="deploy_multi_contracts.py"
BENCHCONFIG_RAAC="benchconfig-raac-burst-dynamic.yaml"
GC_PARSER="scripts/parse_besu_gc.py"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
export RAAC_AI_URL="http://127.0.0.1:8000"

wait_for_rpc() {
    local port="${1:-8545}"; local max=120; local c=0
    echo -n "  Waiting for RPC"
    while [ $c -lt $max ]; do
        curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:${port} > /dev/null 2>&1 && echo " READY" && return 0
        echo -n "."; sleep 1; c=$((c+1))
    done
    echo " TIMEOUT"; return 1
}

stop_besu() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0; while kill -0 "${pid}" 2>/dev/null && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
}

# args: mode base_thr min_thr occu_low occu_high gc_log_path heap_only_cutoff dagor_cpu_low dagor_cpu_high
restart_ai_service_with_config() {
    local mode="$1" base_thr="$2" min_thr="$3" occu_low="$4" occu_high="$5" gc_log_path="$6"
    local cutoff="${7:-0.5}" dagor_cpu_low="${8:-100.0}" dagor_cpu_high="${9:-800.0}"
    pkill -f "serve\.py" 2>/dev/null || true
    sleep 2
    cd "${AI_SERVICE_DIR}"
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
    AI_MODE="${mode}" AI_HEAP_ONLY_CUTOFF="${cutoff}" \
    AI_THRESHOLD_BASE="${base_thr}" AI_THRESHOLD_MIN="${min_thr}" \
    AI_GC_LOG_PATH="${gc_log_path}" AI_GC_OCCU_LOW="${occu_low}" AI_GC_OCCU_HIGH="${occu_high}" \
    AI_DAGOR_CPU_LOW="${dagor_cpu_low}" AI_DAGOR_CPU_HIGH="${dagor_cpu_high}" \
    AI_DAGOR_PROCESS_PATTERN="hyperledger.besu.Besu" \
    nohup python3 serve.py > /tmp/serve_ai_full6arm.log 2>&1 &
    echo "  AI service (re)started: mode=${mode} base=${base_thr} min=${min_thr} occu=[${occu_low},${occu_high}] cutoff=${cutoff} dagor_cpu=[${dagor_cpu_low},${dagor_cpu_high}] (PID $!)"
    sleep 6
    cd /home/yeochan.yoon/caliper-stress-test
}

ensure_ai_service() {
    local c=0
    while [ $c -lt 20 ]; do
        result=$(curl -s --max-time 3 http://127.0.0.1:8000/ 2>/dev/null)
        if echo "${result}" | grep -q '"dynamic_threshold"'; then
            echo "  AI service ready: ${result}"
            return 0
        fi
        sleep 2; c=$((c+1))
    done
    echo "  ERROR: AI service failed to respond after 40s"; return 1
}

# args: config rep [occu_low occu_high heap_only_cutoff dagor_cpu_low dagor_cpu_high]
# The optional trailing args let a targeted re-run override the calibrated
# defaults for exactly one arm (e.g. dagor_cpu bounds turned out miscalibrated
# against real observed Besu CPU%) without touching the main script.
run_config() {
    local config="$1"; local rep="$2"
    local override_occu_low="${3:-}" override_occu_high="${4:-}" override_cutoff="${5:-}"
    local override_dagor_low="${6:-}" override_dagor_high="${7:-}"
    local label="${config}_besu_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc_besu.log"

    local tx_pool_max_prioritized="2048"
    local tx_pool_layer_max_capacity="2048"
    local occu_low="0.10" occu_high="0.25"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    case "${config}" in
        static)
            restart_ai_service_with_config "raac" "0.95" "0.95" "${override_occu_low:-0.10}" "${override_occu_high:-0.25}" "${gc_log}"
            ;;
        native_evict)
            restart_ai_service_with_config "raac" "0.95" "0.95" "${override_occu_low:-0.10}" "${override_occu_high:-0.25}" "${gc_log}"
            tx_pool_max_prioritized="64"
            tx_pool_layer_max_capacity="500000"
            ;;
        heap_only)
            restart_ai_service_with_config "heap_only" "0.95" "0.70" "${override_occu_low:-0.10}" "${override_occu_high:-0.25}" "${gc_log}" "${override_cutoff:-0.5}"
            ;;
        dagor)
            restart_ai_service_with_config "dagor" "0.95" "0.70" "${override_occu_low:-0.10}" "${override_occu_high:-0.25}" "${gc_log}" "0.5" "${override_dagor_low:-100}" "${override_dagor_high:-800}"
            ;;
        moderate)
            restart_ai_service_with_config "raac" "0.95" "0.70" "${override_occu_low:-0.10}" "${override_occu_high:-0.25}" "${gc_log}"
            ;;
        aggressive)
            restart_ai_service_with_config "raac" "0.95" "0.70" "${override_occu_low:-0.10}" "${override_occu_high:-0.20}" "${gc_log}"
            ;;
        *)
            echo "Unknown config: ${config}"; return 1 ;;
    esac

    ensure_ai_service || {
        echo "failed=ai_service_down" > "${run_dir}/FAILED"; return 1
    }

    local raac_log_dir="${run_dir}/raac_logs"
    rm -rf "${raac_log_dir}"; mkdir -p "${raac_log_dir}"
    export RAAC_LOG_DIR="${raac_log_dir}"

    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    # -XX:+ExitOnOutOfMemoryError: heap OOM under full attack load is a real,
    # measured failure mode for static/moderate/aggressive/dagor (not just a
    # host-contention artifact — seen at load~5 too). This doesn't fix the
    # crash, but makes it fail fast instead of lingering as an unresponsive
    # zombie for the full 900s caliper timeout, which matters for rerun cycle
    # time. Heap size itself is NOT changed — would break comparability with
    # data already collected tonight at Xmx=1g.
    local java_opts="-Xms${HEAP_BESU} -Xmx${HEAP_BESU} \
-XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=5,filesize=100M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
-Dlast.variant=DISABLED \
-Dlass.old.gen.activation.threshold=2.0"
    export BESU_OPTS="${java_opts}"

    nohup "${BESU_BIN}" \
        --network=dev \
        --miner-enabled \
        --miner-coinbase=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
        --data-path="${data_dir}" \
        --rpc-http-enabled \
        --rpc-http-host=0.0.0.0 \
        --rpc-http-port=8545 \
        --rpc-http-cors-origins="*" \
        --rpc-http-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
        --rpc-ws-enabled \
        --rpc-ws-host=0.0.0.0 \
        --rpc-ws-port=8546 \
        --rpc-ws-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
        --host-allowlist="*" \
        --min-gas-price=0 \
        --tx-pool-max-prioritized="${tx_pool_max_prioritized}" \
        --tx-pool-layer-max-capacity="${tx_pool_layer_max_capacity}" \
        --logging=INFO \
        > "${run_dir}/besu_console.log" 2>&1 &
    local pid=$!; echo "  Besu PID: ${pid}"
    unset BESU_OPTS

    sleep 8
    if ! kill -0 ${pid} 2>/dev/null; then
        echo "failed=startup" > "${run_dir}/FAILED"
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    fi
    wait_for_rpc || {
        stop_besu "${pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    }

    python3 "${DEPLOY_BESU}" > "${run_dir}/deploy.log" 2>&1
    grep -q "Contract Address:" "${run_dir}/deploy.log" || {
        stop_besu "${pid}"; echo "failed=deploy" > "${run_dir}/FAILED"
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    }
    sleep 5

    cp /tmp/serve_ai_full6arm.log "${run_dir}/ai_service_before.log" 2>/dev/null || true

    echo "  Running Caliper (60s warmup + 90+120+90+120+60s burst pattern)..."
    timeout 900 npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG_RAAC}" \
        --caliper-networkconfig "${NETWORKCONFIG_BESU}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true

    cp /tmp/serve_ai_full6arm.log "${run_dir}/ai_service_after.log" 2>/dev/null || true
    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    # caliper.log is append-only across invocations (never truncated by
    # caliper itself) — reset it now that this run's copy is safely saved,
    # or it grows unbounded across all 48 runs tonight (hit 20GB once already).
    : > caliper.log 2>/dev/null || true

    # Fragmentation fuzz-loop hook: only on the LAST aggressive rep, while the
    # steady-state-stress phase has already lowered the threshold and the node
    # is still live — this is the only point where "does fragmentation evade
    # an already-lowered threshold" is actually being tested.
    if [ "${config}" = "aggressive" ] && [ "${rep}" = "${N_REPS:-}" ]; then
        echo "  Running fragmentation fuzz-loop against live (pressured) node..."
        CONTRACT_ADDR=$(python3 -c "import json; print(json.load(open('deployed_contracts.json'))['addresses'][0])" 2>/dev/null || echo "")
        if [ -n "${CONTRACT_ADDR}" ]; then
            python3.11 scripts/fragmentation_fuzz.py \
                --ai-url http://127.0.0.1:8000 --contract-address "${CONTRACT_ADDR}" \
                --contract-abi StateBloater.json --k-values 1,2,3,4,5,6,8,10 --drip-delay 0 \
                --out "${run_dir}/fragmentation_fast.json" \
                > "${run_dir}/fragmentation_fast.log" 2>&1 || echo "  WARNING: fast fragmentation fuzz failed"
            python3.11 scripts/fragmentation_fuzz.py \
                --ai-url http://127.0.0.1:8000 --contract-address "${CONTRACT_ADDR}" \
                --contract-abi StateBloater.json --k-values 5 --drip-delay 35 \
                --out "${run_dir}/fragmentation_slowdrip.json" \
                > "${run_dir}/fragmentation_slowdrip.log" 2>&1 || echo "  WARNING: slow-drip fragmentation fuzz failed"
        else
            echo "  WARNING: could not resolve contract address for fragmentation fuzz-loop"
        fi
    fi

    stop_besu "${pid}"; rm -rf "${data_dir}"
    unset RAAC_LOG_DIR 2>/dev/null || true

    if [ -f "${gc_log}" ]; then
        gc_out=$(python3 "${GC_PARSER}" \
            --log "${gc_log}" --variant "${config}" --run "${rep}" 2>&1 \
            | grep "total_ms=" | sed 's/.*total_ms=\([0-9.]*\).*/\1/' \
            || echo "parse_error")
        [ -z "${gc_out}" ] && gc_out="no_gc_events"
        echo "${gc_out}" > "${run_dir}/gc_summary.txt"
        echo "  GC: ${gc_out} ms (total STW)"
    else
        echo "  GC: gc_log missing"
    fi

    if ls "${raac_log_dir}"/*.jsonl > /dev/null 2>&1; then
        local total rejects
        total=$(cat "${raac_log_dir}"/*.jsonl | wc -l || echo 0)
        rejects=$(grep -h '"ai_action":"reject"' "${raac_log_dir}"/*.jsonl 2>/dev/null | wc -l || echo 0)
        echo "  RAAC total: rejects=${rejects}/${total}"
    fi

    grep "Transaction Info\|Summary" "${run_dir}/caliper_console.log" 2>/dev/null | \
        tail -5 | sed 's/^/  Caliper: /' || true
    echo "  ✓ ${label} complete"
}
