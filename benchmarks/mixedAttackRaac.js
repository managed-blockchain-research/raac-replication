'use strict';

/**
 * Mixed Attack Workload — RAAC Enabled
 * 90% "normal" txs: StateBloater.bloat(startIdx, 1)  — queried as NORMAL_FEATURES
 * 10% "attack" txs: StateBloater.bloat(startIdx, 200) — queried as ATTACK_FEATURES
 *
 * Before each tx, posts to AI service at RAAC_AI_URL (/predict).
 * If the AI returns "reject", the tx is NOT submitted (RAAC admission control).
 * All classification decisions are logged for TPR/FPR computation.
 *
 * Set RAAC_AI_URL env var (default: http://127.0.0.1:8000).
 */

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const http = require('http');
const fs = require('fs');
const path = require('path');

const ATTACK_RATIO = 0.30;
const NORMAL_SLOTS = 1;
const ATTACK_SLOTS = 200;  // 200 SSTOREs (~4M gas, within 8M gasLimit)

const AI_URL = process.env.RAAC_AI_URL || 'http://127.0.0.1:8000';

// Feature vectors matching banning/ai_service classification logic
const NORMAL_FEATURES = {
    gas_price:     50,
    gas_limit:     21_000,
    wei_value:     1_000_000_000_000_000_000,
    bytecode_size: 0,
    opcode_count:  10,
    call_depth:    0,
    sstore_count:  0,
};

const ATTACK_FEATURES = {
    gas_price:     1,
    gas_limit:     12_000_000,
    wei_value:     0,
    bytecode_size: 24_000,
    opcode_count:  40_000,
    call_depth:    12,
    sstore_count:  150,
};

function httpPost(url, body) {
    return new Promise((resolve, reject) => {
        const data = JSON.stringify(body);
        const u = new URL(url);
        const options = {
            hostname: u.hostname,
            port:     u.port || 80,
            path:     u.pathname,
            method:   'POST',
            headers:  { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) },
        };
        const req = http.request(options, (res) => {
            let raw = '';
            res.on('data', (c) => raw += c);
            res.on('end', () => {
                try { resolve(JSON.parse(raw)); }
                catch (e) { resolve({ action: 'accept' }); }
            });
        });
        req.on('error', () => resolve({ action: 'accept' })); // fail-open on timeout
        req.setTimeout(2000, () => { req.destroy(); resolve({ action: 'accept' }); });
        req.write(data);
        req.end();
    });
}

class MixedAttackRaacWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex = 0;
        this.contractId = null;
        this.normalCount = 0;
        this.attackCount = 0;
        this.raacAllowed = 0;
        this.raacBlocked = 0;
        this.fpCount = 0;  // false positives: normal tx blocked
        this.tpCount = 0;  // true positives:  attack tx blocked
        this.logStream = null;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);

        const args = this.roundArguments || {};
        const numContracts = args.numContracts || 30;
        const prefix = args.contractPrefix || 'SB';
        this.contractId = `${prefix}${workerIndex % numContracts}`;

        // logDir from roundArguments or RAAC_LOG_DIR env var
        const logDir = args.logDir || process.env.RAAC_LOG_DIR || null;
        if (logDir) {
            const logFile = path.join(logDir, `worker${workerIndex}_raac.jsonl`);
            this.logStream = fs.createWriteStream(logFile, { flags: 'a' });
        }

        console.log(`[MixedAttack/RAAC] Worker ${workerIndex} → contract ${this.contractId} | AI: ${AI_URL}`);
    }

    async submitTransaction() {
        this.txIndex++;
        const isAttack = Math.random() < ATTACK_RATIO;
        const slots = isAttack ? ATTACK_SLOTS : NORMAL_SLOTS;
        const features = isAttack ? ATTACK_FEATURES : NORMAL_FEATURES;
        const txHash = `0x${this.workerIndex.toString(16).padStart(4,'0')}${this.txIndex.toString(16).padStart(8,'0')}`;

        if (isAttack) this.attackCount++;
        else this.normalCount++;

        // Query AI service
        const aiResp = await httpPost(`${AI_URL}/predict`, { tx_hash: txHash, ...features });
        const blocked = (aiResp.action === 'reject');

        if (blocked) {
            this.raacBlocked++;
            if (isAttack) this.tpCount++;
            else this.fpCount++;
        } else {
            this.raacAllowed++;
        }

        if (this.logStream) {
            this.logStream.write(JSON.stringify({
                worker:         this.workerIndex,
                txIndex:        this.txIndex,
                type:           isAttack ? 'attack' : 'normal',
                slots,
                ai_action:      aiResp.action,
                anomaly_score:  aiResp.anomaly_score,
                dyn_threshold:  aiResp.dynamic_threshold,
                submitted:      !blocked,
            }) + '\n');
        }

        if (blocked) {
            // RAAC blocks this tx — do not submit
            return;
        }

        const startIdx = (this.workerIndex * 10_000_000) + (this.txIndex * ATTACK_SLOTS);
        const request = {
            contract: this.contractId,
            verb:     'bloat',
            args:     [startIdx, slots],
            readOnly: false,
        };

        await this.sutAdapter.sendRequests(request);
    }

    async cleanupWorkloadModule() {
        if (this.logStream) this.logStream.end();
        const tpr = this.attackCount > 0 ? (this.tpCount / this.attackCount * 100).toFixed(1) : 'N/A';
        const fpr = this.normalCount > 0 ? (this.fpCount / this.normalCount * 100).toFixed(1) : 'N/A';
        console.log(`[MixedAttack/RAAC] Worker ${this.workerIndex}: ` +
            `normal=${this.normalCount} attack=${this.attackCount} | ` +
            `allowed=${this.raacAllowed} blocked=${this.raacBlocked} | ` +
            `TPR=${tpr}% FPR=${fpr}%`);
    }
}

function createWorkloadModule() {
    return new MixedAttackRaacWorkload();
}

module.exports.createWorkloadModule = createWorkloadModule;
