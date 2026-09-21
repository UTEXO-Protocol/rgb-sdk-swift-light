import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const [baseline, current, output] = process.argv.slice(2);
assert(baseline && current && output, 'usage: verify-api-negative.mjs BASELINE CURRENT NEGATIVE');
const value = JSON.parse(readFileSync(current, 'utf8'));
assert(Array.isArray(value.ABIRoot?.children), 'Unexpected Swift API digester schema');
const count = value.ABIRoot.children.length;
value.ABIRoot.children = value.ABIRoot.children.filter(node => node.name !== 'UTEXOWallet');
assert(value.ABIRoot.children.length < count, 'Negative probe did not remove UTEXOWallet');
writeFileSync(output, JSON.stringify(value), { flag: 'wx' });
const result = spawnSync('xcrun', [
  'swift-api-digester', '-diagnose-sdk', '-error-on-abi-breakage', '-compiler-style-diags',
  '-swift-only', '-disable-os-checks', '-ignore-spi-group', 'Backend',
  '-input-paths', baseline, '-input-paths', output,
], { encoding: 'utf8' });
assert(!result.error, String(result.error));
assert(result.status !== null && result.status !== 0, 'API-removal probe incorrectly passed');
assert(/UTEXOWallet.*(removed|missing)|removed.*UTEXOWallet/i.test(result.stderr + result.stdout),
  `Unexpected negative-probe failure: ${result.stderr}${result.stdout}`);
console.log('API-removal negative control correctly rejects a missing public UTEXOWallet.');
