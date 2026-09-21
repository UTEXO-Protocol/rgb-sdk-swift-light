import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readdirSync, lstatSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const expectedPath = resolve(root, 'Sources/RGBSDK/PrivacyInfo.xcprivacy');
const plist = path => JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', path], { encoding: 'utf8' }));
const expected = plist(expectedPath);
assert.equal(expected.NSPrivacyTracking, false);
assert.deepEqual(expected.NSPrivacyTrackingDomains, []);
assert.deepEqual(expected.NSPrivacyAccessedAPITypes, [{
  NSPrivacyAccessedAPIType: 'NSPrivacyAccessedAPICategoryFileTimestamp',
  NSPrivacyAccessedAPITypeReasons: ['C617.1', '3B52.1'],
}]);
assert.deepEqual(expected.NSPrivacyCollectedDataTypes.map(entry => entry.NSPrivacyCollectedDataType).sort(),
  ['NSPrivacyCollectedDataTypeOtherFinancialInfo', 'NSPrivacyCollectedDataTypeUserID']);
for (const entry of expected.NSPrivacyCollectedDataTypes) {
  assert.equal(entry.NSPrivacyCollectedDataTypeLinked, true);
  assert.equal(entry.NSPrivacyCollectedDataTypeTracking, false);
  assert.deepEqual(entry.NSPrivacyCollectedDataTypePurposes, ['NSPrivacyCollectedDataTypePurposeAppFunctionality']);
}
const path = process.argv[2] ?? resolve(root, 'Artifacts/RGBSDK.xcframework');
const found = [];
function walk(path) {
  const state = lstatSync(path);
  if (state.isSymbolicLink()) return;
  if (state.isDirectory()) for (const name of readdirSync(path)) walk(resolve(path, name));
  else if (path.endsWith('/PrivacyInfo.xcprivacy')) found.push(path);
}
walk(path);
assert(found.length > 0, 'No SDK privacy manifest was packaged');
if (!process.argv[2]) {
  const distribution = plist(resolve(path, 'Info.plist'));
  const expectedManifests = distribution.AvailableLibraries.map(library =>
    resolve(path, library.LibraryIdentifier, library.LibraryPath, 'PrivacyInfo.xcprivacy'));
  assert.equal(expectedManifests.length, 3, 'Unexpected public framework platform slices');
  assert.deepEqual([...found].sort(), expectedManifests.sort(), 'Each framework slice must contain its SDK privacy manifest');
}
for (const manifest of found) {
  assert.deepEqual(plist(manifest), expected, `Unexpected privacy declaration: ${manifest}`);
}
if (process.argv[2]) {
  assert(found.some(path => path.includes('RGBSDK')), 'No independently packaged RGBSDK privacy manifest in consumer app');
}
console.log(`Verified ${found.length} packaged SDK privacy manifest(s): ${found.join(', ')}`);
