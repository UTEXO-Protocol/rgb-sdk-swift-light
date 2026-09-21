import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, readdirSync, lstatSync } from 'node:fs';
import { dirname, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const recordPath = resolve(root, 'NativeSource/facade-build.json');
const sha = path => createHash('sha256').update(readFileSync(path)).digest('hex');
function inventory(paths) {
  const result = {};
  function walk(path) {
    const state = lstatSync(path);
    assert(!state.isSymbolicLink(), `Symlinks are not allowed in facade inputs: ${path}`);
    if (state.isDirectory()) {
      for (const entry of readdirSync(path).sort()) walk(resolve(path, entry));
    } else {
      assert(state.isFile(), `Expected a regular file: ${path}`);
      result[relative(root, path)] = sha(path);
    }
  }
  for (const path of paths) walk(resolve(root, path));
  return result;
}
const inputPaths = [
  'Sources', 'Generated', 'Artifacts/UtexoLocalSigner.xcframework',
  'Package.source.swift', 'Scripts/build-facade.sh', 'Scripts/facade-provenance.mjs',
];
const [mode, snapshotPath] = process.argv.slice(2);
if (mode === '--snapshot' && snapshotPath && process.argv.length === 4) {
  writeFileSync(snapshotPath, JSON.stringify(inventory(inputPaths), null, 2) + '\n', { flag: 'wx' });
} else if (mode === '--record' && snapshotPath && process.argv.length === 4) {
  const original = JSON.parse(readFileSync(snapshotPath, 'utf8'));
  assert.deepEqual(inventory(inputPaths), original, 'Build inputs changed during facade build; rebuild required');
  const record = {
    formatVersion: 1,
    builtAt: new Date().toISOString(),
    xcode: execFileSync('xcodebuild', ['-version'], { encoding: 'utf8' }).trim(),
    swift: execFileSync('xcrun', ['swiftc', '--version'], { encoding: 'utf8' }).trim(),
    deploymentTargets: { iOS: '15.0', macOS: '13.0' },
    inputs: original,
    outputs: inventory(['Artifacts/RGBSDK.xcframework']),
    attestation: 'Local build evidence, not an independently signed release attestation',
  };
  writeFileSync(recordPath, JSON.stringify(record, null, 2) + '\n');
  console.log(`Recorded facade build provenance: ${recordPath}`);
} else if (mode === '--check' && process.argv.length === 3) {
  const record = JSON.parse(readFileSync(recordPath, 'utf8'));
  assert.equal(record.formatVersion, 1);
  assert.deepEqual(inventory(inputPaths), record.inputs, 'Source/native inputs changed; rebuild facade');
  assert.deepEqual(inventory(['Artifacts/RGBSDK.xcframework']), record.outputs, 'Facade files changed or drifted');
  console.log(`Facade input/output inventories match (${Object.keys(record.inputs).length} inputs, ${Object.keys(record.outputs).length} outputs).`);
} else {
  throw new Error('usage: node Scripts/facade-provenance.mjs --snapshot PATH | --record PATH | --check');
}
