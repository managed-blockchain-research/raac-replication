#!/usr/bin/env bash
# NM (Nethermind) equivalent of raac_arm_functions.sh — same 6 arms, adapted to
# .NET/Nethermind specifics: RSS-based pressure signal (not GC log), dotnet-trace
# for GC measurement (not -Xlog:gc), TxPool.Size for native eviction (not
# tx-pool-layer-max-capacity byte cap — NM doesn't expose one).
#
# IMPORTANT: NM and Besu share ports 8545/8546 and the AI service port 8000 —
# never run this concurrently with run_raac_full_6arm.sh (Besu). Same rule as
# AGENTS.md item 7.

DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
# Clique PoA, not NethDev — NethDev has a hard-coded 5-tx/block ceiling that a
# 30-worker/100tps attack burst blows straight through no matter what the
# admission-control policy does (confirmed: 99.98% eth_sendRawTransaction
# failures under static/no-control). XRAY hit the exact same wall and fixed it
# by moving to Clique ("NethDev ceiling is uncontrolled confound") — reusing
# that fix here. HEAP_NM stays at RAAC's own calibrated 4GB (NOT XRAY's 64GB
# production-equivalent heap) since RAAC's whole point is a memory-constrained
# heap that the attack workload can actually pressure.
NM_DLL="/home/yeochan.yoon/nethermind/src/Nethermind/artifacts/bin/Nethermind.Runner/release/nethermind.dll"
CHAINSPEC_NM="/home/yeochan.yoon/banning/raac_clique_nm.json"
SEALER_KEY_NM="/home/yeochan.yoon/banning/experiments/xray/scripts/xray_sealer.key"
HEAP_NM=4000000000
NETWORKCONFIG_NM="networkconfig_nethermind_caliper.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"
BENCHCONFIG_RAAC="benchconfig-raac-burst-dynamic.yaml"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
GC_PARSER_NM="/home/yeochan.yoon/banning/experiments/raac/scripts/parse_gc_nettrace/bin/Release/net10.0/parse_gc_nettrace"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
export RAAC_AI_URL="http://127.0.0.1:8000"

wait_for_rpc_nm() {
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

stop_nm() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0; while kill -0 "${pid}" 2>/dev/null && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

# args: mode base_thr min_thr delta_low delta_high heap_only_cutoff dagor_cpu_low dagor_cpu_high
restart_ai_service_nm() {
    local mode="$1" base_thr="$2" min_thr="$3" delta_low="$4" delta_high="$5"
    local cutoff="${6:-0.5}" dagor_cpu_low="${7:-100.0}" dagor_cpu_high="${8:-800.0}"
    pkill -f "serve\.py" 2>/dev/null || true
    sleep 2
    cd "${AI_SERVICE_DIR}"
    # AI service's asyncio accept loop spins on EMFILE under heavy attack-burst
    # connection volume when the default soft limit (1024) is hit — floods
    # logs with millions of "Too many open files" tracebacks and burns CPU,
    # which can starve the monitored node too. Hard limit is 262144; raise
    # the soft limit for this process (and its nohup'd child) accordingly.
    ulimit -n 65536
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
    AI_MODE="${mode}" AI_HEAP_ONLY_CUTOFF="${cutoff}" \
    AI_THRESHOLD_BASE="${base_thr}" AI_THRESHOLD_MIN="${min_thr}" \
    AI_DELTA_LOW_MB="${delta_low}" AI_DELTA_HIGH_MB="${delta_high}" \
    AI_TARGET_PROCESS_PATTERN="nethermind.dll" \
    AI_DAGOR_CPU_LOW="${dagor_cpu_low}" AI_DAGOR_CPU_HIGH="${dagor_cpu_high}" \
    AI_DAGOR_PROCESS_PATTERN="nethermind.dll" \
    nohup python3 serve.py > /tmp/serve_ai_nm_full6arm.log 2>&1 &
    echo "  AI service (re)started: mode=${mode} base=${base_thr} min=${min_thr} delta=[${delta_low},${delta_high}]MB cutoff=${cutoff} dagor_cpu=[${dagor_cpu_low},${dagor_cpu_high}] (PID $!)"
    sleep 6
    cd /home/yeochan.yoon/caliper-stress-test
}

ensure_ai_service_nm() {
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

# args: config rep
run_config_nm() {
    local config="$1"; local rep="$2"
    local label="${config}_nm_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_${RUN_ID}"
    local nettrace="${run_dir}/gc_trace.nettrace"
    # 8192: validated to survive the full 6-round pattern (60+90+120+90+120+60s,
    # 30 workers/100tps) with zero failures in every round, including the
    # calm round immediately after an attack burst — smaller sizes (4096 and
    # below) leave enough of a backlog that the following calm round shows
    # 0% success. See project_raac_resubmission memory for the full story.
    local txpool_size="8192"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    case "${config}" in
        static)
            restart_ai_service_nm "raac" "0.95" "0.95" "100" "350"
            ;;
        native_evict)
            restart_ai_service_nm "raac" "0.95" "0.95" "100" "350"
            # 2048 (not 8192): small enough to show meaningful degradation
            # during attack bursts (~11-37% success, vs 8192's ~95%+) while
            # still fully recovering to 0-fail during the following calm
            # round — the intended "naive capacity eviction can't tell
            # attack from legit traffic" contrast. 512/1024 both showed
            # permanent 0%-success collapse after the first burst (no
            # recovery for the rest of the test) — too extreme to be a
            # useful ablation baseline.
            txpool_size="2048"
            ;;
        heap_only)
            # Redesign 2026-07-24 (raac-experiment-redesign debate): delta
            # bands tightened from 100/250 -- the wide band let RSS commit
            # hundreds of MB before meaningful rejection engaged (confirmed:
            # aggressive_nm_1 stayed pinned at pressure=1.0 for ~95s while
            # RSS still climbed 1.25GB past the heap limit before death).
            # See ai_service/serve.py's absolute-ceiling term + graduated
            # reject-probability mechanism for the companion fixes.
            #
            # Update 2026-07-24 (2nd redesign pass): even with those fixes,
            # heap_only/moderate/aggressive still die deterministically at
            # round 2 (n=3 pilot, RUN_ID 20260724_114756) -- confirmed the
            # bottleneck isn't reaction speed: pressure hit 1.0 (max reject)
            # well before RSS peaked, yet RSS still climbed ~1.1GB further
            # before plateauing. Admission control alone can't undo memory
            # already committed by tx sitting in NM's pool waiting for block
            # inclusion -- it only gates future submissions. Testing whether
            # combining admission control with native_evict's own pool-bound
            # mechanism (same 2048 cap) helps: RAAC's score-gating should
            # keep the pool mostly clear of attack tx once pressure engages,
            # while the smaller cap bounds worst-case backlog regardless of
            # how fast that engagement happens. NOTE: Besu already runs
            # heap_only/moderate/aggressive at a small 2048/2048 pool by
            # default and STILL fails to complete rounds there -- this is
            # NOT a guaranteed fix, it's an architectural experiment worth
            # running given NM and Besu have diverged on every other arm
            # (dagor, native_evict) throughout this project.
            restart_ai_service_nm "heap_only" "0.95" "0.70" "50" "150"
            txpool_size="2048"
            ;;
        dagor)
            restart_ai_service_nm "dagor" "0.95" "0.70" "100" "350" "0.5" "100" "800"
            ;;
        moderate)
            restart_ai_service_nm "raac" "0.95" "0.70" "40" "120"
            txpool_size="2048"  # see heap_only's comment above -- same pool-bound experiment
            ;;
        aggressive)
            restart_ai_service_nm "raac" "0.95" "0.70" "25" "80"
            txpool_size="2048"  # see heap_only's comment above -- same pool-bound experiment
            ;;
        *)
            echo "Unknown config: ${config}"; return 1 ;;
    esac

    ensure_ai_service_nm || {
        echo "failed=ai_service_down" > "${run_dir}/FAILED"; return 1
    }

    local raac_log_dir="${run_dir}/raac_logs"
    rm -rf "${raac_log_dir}"; mkdir -p "${raac_log_dir}"
    export RAAC_LOG_DIR="${raac_log_dir}"

    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    # Server GC (not Workstation) — matches XRAY's fix; per-core heaps scale
    # better under the 30-worker concurrent load that was starving NethDev.
    export DOTNET_GCHeapHardLimit="${HEAP_NM}"
    export COMPlus_GCHeapHardLimit="${HEAP_NM}"
    export DOTNET_gcServer=1
    export COMPlus_gcServer=1
    export DOTNET_EnableDiagnostics=1
    unset DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true

    nohup "${DOTNET_BIN}" "${NM_DLL}" \
        --Init.ChainSpecPath "${CHAINSPEC_NM}" \
        --Init.BaseDbPath "${data_dir}" \
        --Init.EnableUnsecuredDevWallet true \
        --Init.KeepDevWalletInMemory true \
        --Init.DiagnosticMode MemDb \
        --Init.DiscoveryEnabled false \
        --Init.PeerManagerEnabled false \
        --Init.MemoryHint 2000000000 \
        --KeyStore.EnodeKeyFile "${SEALER_KEY_NM}" \
        --Mining.Enabled true \
        --JsonRpc.Enabled true --JsonRpc.Host 0.0.0.0 --JsonRpc.Port 8545 --JsonRpc.Timeout 20000 \
        --JsonRpc.EnabledModules "Eth,Net,Web3,Debug,Admin,TxPool,Clique" \
        --Sync.NetworkingEnabled false --Sync.SynchronizationEnabled false \
        --Network.DiscoveryPort 0 --Network.P2PPort 0 \
        --Blocks.MinGasPrice 0 --Blocks.TargetBlockGasLimit 1000000000 \
        --TxPool.Size "${txpool_size}" --TxPool.BlobsSupport Disabled \
        --Merge.Enabled false \
        > "${run_dir}/nm_console.log" 2>&1 &
    local pid=$!; echo "  NM PID: ${pid}"

    sleep 8
    if ! kill -0 ${pid} 2>/dev/null; then
        echo "failed=startup" > "${run_dir}/FAILED"
        unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_gcServer COMPlus_gcServer
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    fi
    wait_for_rpc_nm || {
        stop_nm "${pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_gcServer COMPlus_gcServer
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    }

    node "${DEPLOY_NM}" > "${run_dir}/deploy.log" 2>&1
    grep -q "Contract Address:\|SB0:" "${run_dir}/deploy.log" || {
        stop_nm "${pid}"; echo "failed=deploy" > "${run_dir}/FAILED"
        unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_gcServer COMPlus_gcServer
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    }
    sleep 5

    local dt_pid=""
    [ -f "${DT_BIN}" ] && {
        "${DT_BIN}" collect --process-id "${pid}" --profile gc-collect \
            --output "${nettrace}" > "${run_dir}/dotnet_trace.log" 2>&1 &
        dt_pid=$!; echo "  dotnet-trace PID: ${dt_pid}"
    }

    cp /tmp/serve_ai_nm_full6arm.log "${run_dir}/ai_service_before.log" 2>/dev/null || true

    echo "  Running Caliper (60s warmup + 90+120+90+120+60s burst pattern)..."
    # UPDATE 2026-08-02: 900s was too tight -- static_nm_1's own rounds 1-5 alone
    # summed to ~813s (89+130+228+99+267s, all individually reasonable for NM's
    # own known-slower profile vs Besu), leaving calm-3 almost no room and
    # getting killed mid-round twice in a row (attempts 1-2, same anomaly both
    # times -- not host-contention noise). Raised to 3600s to match Besu's own
    # default outer_timeout, comfortably covering a full 6-round NM rep even
    # under slow conditions.
    timeout 3600 npx caliper launch manager \
        --caliper-workspace ./ --caliper-benchconfig "${BENCHCONFIG_RAAC}" \
        --caliper-networkconfig "${NETWORKCONFIG_NM}" \
        > "${run_dir}/caliper_console.log" 2>&1 &
    local caliper_pid=$!

    # Fragmentation fuzz-loop hook (NM leg): only on the LAST aggressive rep.
    # Unlike Besu (whose post-GC-occupancy pressure signal was found, via
    # smoke test, to stay under its activation threshold even under heavy
    # GC churn -- G1GC reclaims too effectively for this signal design to
    # register elevated pressure), NM's RSS-based pressure signal is
    # confirmed via the backlog-momentum finding to elevate substantially
    # AND persist for minutes after an attack burst -- a much better
    # candidate for testing "does fragmentation evade an already-elevated
    # threshold." Poll for the same caliper round-orchestrator marker used
    # by the Besu leg (same BENCHCONFIG_RAAC, so identical phase labels)
    # rather than a fixed sleep, since round durations are transaction-count-
    # based and stretch under host contention (confirmed empirically on the
    # Besu leg).
    local fuzz_pid=""
    if [ "${config}" = "aggressive" ] && [ "${rep}" = "${N_REPS:-}" ]; then
        (
            local waited=0
            while [ "${waited}" -lt 700 ]; do
                grep -q "Started round 5 (attack-burst-2)" "${run_dir}/caliper_console.log" 2>/dev/null && break
                sleep 5
                waited=$((waited + 5))
            done
            if [ "${waited}" -ge 700 ]; then
                echo "  WARNING: attack-burst-2 phase marker never appeared after 700s -- firing fuzz-loop anyway (best-effort, likely uninformative)"
            else
                sleep 20   # let RSS pressure build a bit within the steady-state-stress round before probing
            fi
            echo "  Running fragmentation fuzz-loop against live (pressured) NM node..."
            CONTRACT_ADDR=$(python3 -c "import json; print(json.load(open('deployed_contracts_nm.json'))['addresses'][0])" 2>/dev/null || echo "")
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
        ) &
        fuzz_pid=$!
    fi

    wait "${caliper_pid}" || true
    [ -n "${fuzz_pid}" ] && { wait "${fuzz_pid}" 2>/dev/null || true; }

    cp /tmp/serve_ai_nm_full6arm.log "${run_dir}/ai_service_after.log" 2>/dev/null || true
    [ -n "${dt_pid}" ] && kill -INT "${dt_pid}" 2>/dev/null || true
    sleep 8; [ -n "${dt_pid}" ] && kill "${dt_pid}" 2>/dev/null || true

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    : > caliper.log 2>/dev/null || true

    stop_nm "${pid}"; rm -rf "${data_dir}"
    unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_gcServer COMPlus_gcServer \
          DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
    unset RAAC_LOG_DIR 2>/dev/null || true

    if [ -f "${nettrace}" ] && [ -f "${GC_PARSER_NM}" ]; then
        local gc_out
        # tail -1: parse_gc_nettrace prints diagnostic lines then the final
        # numeric summary last (confirmed working pattern from
        # run_raac_eval13_supplement.sh, the script that produced the paper's
        # existing NM numbers).
        gc_out=$("${GC_PARSER_NM}" "${nettrace}" 2>/dev/null | tail -1 || echo "parse_error")
        echo "${gc_out}" > "${run_dir}/gc_summary.txt"
        echo "  GC: ${gc_out}"
    else
        echo "no_gc_events" > "${run_dir}/gc_summary.txt"
        echo "  GC: gc_trace or parser missing"
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
