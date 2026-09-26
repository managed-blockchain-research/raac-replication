'use strict';

/**
 * Burst Attack Workload — Allocator-Threshold Straddling Sweep (2026-09-24
 * ETRI resubmission pass). Copy+diff-edit of mixedAttackLOHRaacBurst.js
 * (never rewrite from scratch, per project convention) -- the only change
 * is that the attack payload size is no longer a fixed 96,000-byte
 * constant: it is read per-run from RAAC_ATTACK_PAYLOAD_BYTES (a single
 * fixed size, e.g. 12000 for the "8x12KB" sweep point), or, when
 * RAAC_ATTACK_SHAPE_MIX=1, drawn uniformly at random per attack
 * transaction from RAAC_ATTACK_SHAPE_SET (comma-separated byte sizes) --
 * the "mixed" condition from the allocator-threshold-sweep debate
 * (2026-09-24): does the controller/GC response generalize when shapes
 * vary within a single burst, not just across separate isolated runs.
 *
 * Everything else (attackRatio semantics, self-pacing, dispatch-cap,
 * semaphore-bounded concurrency, AI predict/reject flow) is identical to
 * the original file -- see that file's own comments for the history of
 * why each of those exists. Do not use this file for the six-policy
 * cross-runtime headline evaluation or the Token Bucket baseline; those
 * keep using the original fixed-96KB module unchanged for comparability
 * with all previously published numbers.
 */

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const http = require('http');
const fs   = require('fs');
const path = require('path');

function parseShapeSet(s) {
    return String(s || '96000').split(',').map(x => parseInt(x.trim(), 10)).filter(n => Number.isFinite(n) && n > 0);
}

const SHAPE_MIX      = process.env.RAAC_ATTACK_SHAPE_MIX === '1';
const SHAPE_SET       = parseShapeSet(process.env.RAAC_ATTACK_SHAPE_SET);
const FIXED_PAYLOAD_BYTES = Number(process.env.RAAC_ATTACK_PAYLOAD_BYTES) || 96000;

function attackDataFor(bytes) {
    return '0x' + '00'.repeat(bytes);
}

// Pre-build hex strings for every shape once (avoid re-building a possibly
// large string per transaction): for the fixed-size case this is just the
// one size; for the mix case, one per entry in the shape set.
const ATTACK_DATA_BY_SIZE = new Map();
function getAttackData(bytes) {
    if (!ATTACK_DATA_BY_SIZE.has(bytes)) ATTACK_DATA_BY_SIZE.set(bytes, attackDataFor(bytes));
    return ATTACK_DATA_BY_SIZE.get(bytes);
}

const NORMAL_DATA = '0x';   // empty: 428 txs/block × 178B = 76KB < 85KB LOH threshold
const AI_URL      = process.env.RAAC_AI_URL || 'http://127.0.0.1:8000';
const TARGET_TPS  = Number(process.env.RAAC_TARGET_TPS) || 100;
const MAX_INFLIGHT = Number(process.env.RAAC_MAX_INFLIGHT) || 5;

class Semaphore {
    constructor(max) { this.max = max; this.count = 0; this.queue = []; }
    async acquire() {
        if (this.count < this.max) { this.count++; return; }
        await new Promise(resolve => this.queue.push(resolve));
        this.count++;
    }
    release() {
        this.count--;
        const next = this.queue.shift();
        if (next) next();
    }
}

const NORMAL_FEATURES = {
    gas_price: 50, gas_limit: 21_000, wei_value: 1_000_000_000_000_000_000,
    bytecode_size: 0, opcode_count: 10, call_depth: 0, sstore_count: 0,
};

function attackFeaturesFor(bytes) {
    // Scaled proportionally from the original 96KB ATTACK_FEATURES, matching
    // fragmentation_fuzz.py's build_chunk_features() precedent for scaling
    // feature magnitude with actual payload size rather than using a fixed
    // feature vector regardless of the swept shape.
    const scale = bytes / 96_000;
    return {
        gas_price: 50, gas_limit: Math.round(12_000_000 * scale) || 21_000, wei_value: 0,
        bytecode_size: bytes, opcode_count: Math.round(40_000 * scale), call_depth: 12, sstore_count: 0,
    };
}

// 2026-09-24: same fix as mixedAttackLOHRaacBurst.js -- bound sendRequests()
// so a single RPC-layer hang (documented socket-starvation issue) can't
// stall an entire round forever. See that file's comment for the full story.
const SEND_TIMEOUT_MS = 30_000;
function withTimeout(promise, ms) {
    let timer;
    const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`sendRequests timed out after ${ms}ms`)), ms);
    });
    return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function httpPost(url, body) {
    return new Promise((resolve) => {
        const data = JSON.stringify(body);
        const u    = new URL(url);
        const opts = {
            hostname: u.hostname, port: u.port || 80, path: u.pathname,
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) },
        };
        const req = http.request(opts, (res) => {
            let raw = '';
            res.on('data', c => raw += c);
            res.on('end', () => { try { resolve(JSON.parse(raw)); } catch { resolve({ action: 'accept' }); } });
        });
        req.on('error', () => resolve({ action: 'accept' }));
        req.setTimeout(2000, () => { req.destroy(); resolve({ action: 'accept' }); });
        req.write(data); req.end();
    });
}

class ShapeSweepBurstWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex     = 0;
        this.contractId  = null;
        this.attackRatio = 0;
        this.normalCount = 0;
        this.attackCount = 0;
        this.raacBlocked = 0;
        this.tpCount     = 0;
        this.fpCount     = 0;
        this.logStream   = null;
        this._firstAttemptTime = null;
        this._inflightSem = new Semaphore(MAX_INFLIGHT);
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);

        const args         = this.roundArguments || {};
        const numContracts = args.numContracts || 30;
        const prefix       = args.contractPrefix || 'SB';
        this.contractId    = `${prefix}${workerIndex % numContracts}`;
        this.attackRatio   = typeof args.attackRatio === 'number' ? args.attackRatio : 0;
        this._firstAttemptTime = null;

        const roundDurationSeconds = Number(args.roundDurationSeconds) || 0;
        const tpsPerWorkerForCap = TARGET_TPS / totalWorkers;
        this._maxAttempts = roundDurationSeconds > 0 && tpsPerWorkerForCap > 0
            ? Math.ceil(tpsPerWorkerForCap * roundDurationSeconds * 1.05)
            : Infinity;

        const logDir = args.logDir || process.env.RAAC_LOG_DIR || null;
        if (logDir) {
            const label   = args.roundLabel || 'round';
            const logFile = path.join(logDir, `worker${workerIndex}_${label}_raac.jsonl`);
            this.logStream = fs.createWriteStream(logFile, { flags: 'a' });
        }

        console.log(`[ShapeSweep] Worker ${workerIndex} → ${this.contractId} | attackRatio=${this.attackRatio} | `
            + `shapeMix=${SHAPE_MIX} shapeSet=[${SHAPE_SET}] fixedPayloadBytes=${FIXED_PAYLOAD_BYTES} | AI: ${AI_URL}`);
    }

    async submitTransaction() {
        if (this.txIndex >= this._maxAttempts) {
            await new Promise(resolve => setTimeout(resolve, 200));
            return;
        }

        const myIndex = this.txIndex;
        this.txIndex++;

        const tpsPerWorker = TARGET_TPS / this.totalWorkers;
        if (tpsPerWorker > 0) {
            const sleepTimeMs = 1000 / tpsPerWorker;
            if (this._firstAttemptTime === null) this._firstAttemptTime = Date.now();
            const diff = sleepTimeMs * myIndex - (Date.now() - this._firstAttemptTime);
            if (diff > 0) await new Promise(resolve => setTimeout(resolve, diff));
        }

        const isAttack = Math.random() < this.attackRatio;
        const payloadBytes = isAttack
            ? (SHAPE_MIX ? SHAPE_SET[Math.floor(Math.random() * SHAPE_SET.length)] : FIXED_PAYLOAD_BYTES)
            : 0;
        const features  = isAttack ? attackFeaturesFor(payloadBytes) : NORMAL_FEATURES;
        const txHash    = `0x${this.workerIndex.toString(16).padStart(4,'0')}${(myIndex + 1).toString(16).padStart(8,'0')}`;

        if (isAttack) this.attackCount++; else this.normalCount++;

        await this._inflightSem.acquire();
        try {
            const aiResp  = await httpPost(`${AI_URL}/predict`, { tx_hash: txHash, ...features });
            const blocked = aiResp.action === 'reject';

            if (blocked) {
                this.raacBlocked++;
                if (isAttack) this.tpCount++; else this.fpCount++;
            }

            if (this.logStream) {
                this.logStream.write(JSON.stringify({
                    worker:            this.workerIndex,
                    txIndex:           this.txIndex,
                    type:              isAttack ? 'attack' : 'normal',
                    payload_bytes:     isAttack ? payloadBytes : 0,
                    ai_action:         aiResp.action,
                    anomaly_score:     aiResp.anomaly_score,
                    dyn_threshold:     aiResp.dynamic_threshold,
                    gc_pressure:       aiResp.gc_pressure,
                    submitted:         !blocked,
                }) + '\n');
            }

            if (blocked) return;

            let request;
            if (isAttack) {
                request = { contract: this.contractId, verb: 'sink', args: [getAttackData(payloadBytes)], readOnly: false };
            } else {
                request = { contract: this.contractId, verb: 'sink', args: [NORMAL_DATA], readOnly: false };
            }
            try {
                await withTimeout(this.sutAdapter.sendRequests(request), SEND_TIMEOUT_MS);
            } catch (err) {
                if (this.logStream) {
                    this.logStream.write(JSON.stringify({ worker: this.workerIndex, txIndex: this.txIndex, error: String(err && err.message || err) }) + '\n');
                }
            }
        } finally {
            this._inflightSem.release();
        }
    }

    async cleanupWorkloadModule() {
        if (this.logStream) this.logStream.end();
        const tpr = this.attackCount > 0 ? (this.tpCount / this.attackCount * 100).toFixed(1) : 'N/A';
        const fpr = this.normalCount > 0 ? (this.fpCount / this.normalCount * 100).toFixed(1) : 'N/A';
        console.log(`[ShapeSweep] Worker ${this.workerIndex}: ` +
            `normal=${this.normalCount} attack=${this.attackCount} ` +
            `blocked=${this.raacBlocked} TPR=${tpr}% FPR=${fpr}%`);
    }
}

module.exports.createWorkloadModule = () => new ShapeSweepBurstWorkload();
