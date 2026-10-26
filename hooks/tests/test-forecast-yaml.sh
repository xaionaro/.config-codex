#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
node - "$root" <<'NODE'
const fs = require('fs');
const YAML = require('yaml');
const path = require('path');
const assert = require('assert');
const examples = path.join(process.argv[2], 'skills/context-ledger/examples');
const parse = file => YAML.parse(fs.readFileSync(path.join(examples, file), 'utf8'), {uniqueKeys:true, stringKeys:true, maxAliasCount:0});
const ledger = parse('project-understanding.yaml');
const forecasts = parse('forecasts.yaml');
assert.strictEqual(forecasts.schema, 'forecasts/v1');
const ref = ledger.records['work:receiver:clock'].data.forecast_ref;
const match = /^forecasts\.yaml#\/records\/([a-z0-9_:-]+)$/.exec(ref);
assert(match, 'forecast reference must be a stable record pointer');
const record = forecasts.records[match[1]];
assert(record, 'forecast reference must resolve');
assert.strictEqual(record.kind, 'lane');
assert.strictEqual(record.status, 'active');
assert.strictEqual(record.assessment, 'provisional');
for (const key of ['outcome', 'target', 'target_basis', 'original_baseline', 'baseline_evidence']) assert(record[key], key);
for (const key of ['prior', 'current', 'reason', 'evidence']) assert(record.recalibration[key], key);
assert.strictEqual(record.recalibration.current, record.target);
assert(record.base_case.endpoint && record.base_case.packages[0].basis);
const scenario = record.scenarios[0];
for (const key of ['name', 'trigger', 'affected_work', 'evidence', 'assumptions', 'added_duration', 'event_time', 'endpoint', 'basis', 'evidence_gap', 'next_action']) assert(scenario[key], key);
console.log('forecast YAML fixture and locator: PASS');
NODE
