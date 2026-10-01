import assert from 'node:assert/strict';
import { chmodSync, cpSync, existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const planner = () => import('../.claude/skills/verify-ios/helpers/sim-plan.mjs');

test('build folder parsing preserves the default and lets the flag override the environment', async () => {
  const { parseOptions } = await planner();
  assert.equal(parseOptions(['build'], {}, '/tree').buildFolder, '/tree/DerivedData');
  assert.equal(parseOptions(['build'], { ENDURAGENT_VERIFY_BUILD: '/tmp/env-build' }, '/tree').buildFolder, '/tmp/env-build');
  const parsed = parseOptions(['suite', 'AlphaProof', '--build-folder', '/tmp/flag-build', '--shards', '2', '--timings', '/tmp/times.json'], { ENDURAGENT_VERIFY_BUILD: '/tmp/env-build' }, '/tree');
  assert.deepEqual(parsed, { command: 'suite', args: ['AlphaProof'], buildFolder: '/tmp/flag-build', shards: 2, timings: '/tmp/times.json' });
  for (const args of [['suite', '--shards', '0'], ['suite', '--shards', '1.5'], ['build', '--build-folder'], ['suite', '--timings']]) {
    assert.throws(() => parseOptions(args, {}, '/tree'));
  }
});

test('shard planner covers each class once and balances class counts without timings', async () => {
  const { planShards } = await planner();
  const proofs = ['AlphaProof', 'BravoProof', 'CharlieProof', 'DeltaProof', 'EchoProof'];
  const shards = planShards(proofs, 2);
  assert.deepEqual(shards.map(shard => shard.proofs), [['AlphaProof', 'CharlieProof', 'EchoProof'], ['BravoProof', 'DeltaProof']]);
  assert.deepEqual(shards.flatMap(shard => shard.proofs).sort(), proofs);
  assert.deepEqual(planShards(proofs, 3).map(shard => shard.proofs.length), [2, 2, 1]);
  assert.throws(() => planShards(['AlphaProof', 'AlphaProof'], 2), /duplicate/);
  assert.throws(() => planShards(proofs, 0), /shards/);
  assert.throws(() => planShards(['AlphaProof'], 2), /classes/);
});

test('shard planner uses measured durations and a measured fallback for new classes', async () => {
  const { planShards } = await planner();
  const timings = { AlphaProof: 100, BravoProof: 80, CharlieProof: 20, DeltaProof: 10 };
  const shards = planShards(Object.keys(timings), 2, timings);
  assert.deepEqual(shards.map(shard => shard.estimatedSeconds), [110, 100]);
  const partial = planShards(['AlphaProof', 'NewProof'], 2, { AlphaProof: 100 });
  assert.deepEqual(partial.map(shard => shard.estimatedSeconds), [100, 100]);
  assert.throws(() => planShards(['AlphaProof'], 1, { AlphaProof: -1 }), /duration/);
});

test('test result summary counts skipped tests and missing classes as unverified', async () => {
  const { summarizeTests } = await planner();
  const summary = summarizeTests({ testNodes: [{ children: [
    { nodeType: 'Test Case', nodeIdentifier: 'AlphaProof/testOne()', result: 'Passed', durationInSeconds: 3 },
    { nodeType: 'Test Case', nodeIdentifier: 'AlphaProof/testTwo()', result: 'Skipped', durationInSeconds: 1 },
    { nodeType: 'Test Case', nodeIdentifier: 'BravoProof/testOne()', result: 'Failed', durationInSeconds: 2 },
  ] }] }, ['AlphaProof', 'BravoProof', 'MissingProof']);
  assert.deepEqual(summary, [
    { name: 'AlphaProof', passed: 1, failed: 0, skipped: 1, missing: 0, seconds: 4 },
    { name: 'BravoProof', passed: 0, failed: 1, skipped: 0, missing: 0, seconds: 2 },
    { name: 'MissingProof', passed: 0, failed: 0, skipped: 0, missing: 1, seconds: 0 },
  ]);
});

function exportedTree(t) {
  const root = mkdtempSync(join(tmpdir(), 'enduragent-verify-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const tree = join(root, 'export');
  const helper = join(tree, '.claude/skills/verify-ios/helpers');
  cpSync(resolve('.claude/skills/verify-ios/helpers'), helper, { recursive: true });
  const source = join(tree, 'apps/ios/EnduragentUITests');
  mkdirSync(source, { recursive: true });
  writeFileSync(join(source, 'Proofs.swift'), ['AlphaProof', 'BravoDarkProof', 'CharlieProof'].map(name => `final class ${name}: XCTestCase {}`).join('\n') + '\nfinal class TimingProbe: XCTestCase {}\n');
  const bin = join(root, 'bin');
  mkdirSync(bin);
  for (const tool of ['git', 'xcrun', 'xcodegen', 'xcodebuild', 'plutil', 'date']) {
    const source = readFileSync(resolve('tools/fixtures/verify-ios-tool.mjs'), 'utf8');
    writeFileSync(join(bin, tool), source.replace(/^#![^\n]+/, `#!${process.execPath}`));
    chmodSync(join(bin, tool), 0o755);
  }
  const build = join(root, 'build');
  const runs = join(root, 'runs');
  const env = { ...process.env, PATH: bin, ENDURAGENT_VERIFY_FAKE_ROOT: root, ENDURAGENT_VERIFY_RUNS: runs, ENDURAGENT_VERIFY_BUILD: build };
  for (const key of Object.keys(env).filter(key => key.startsWith('VERIFY_'))) delete env[key];
  const run = (args, extra = {}) => spawnSync(process.execPath, [join(helper, 'sim.mjs'), ...args], { cwd: root, env: { ...env, ...extra }, encoding: 'utf8', timeout: 120000 });
  return { root, tree, build, runs, run };
}

test('fake device listings keep their snapshot when another shard deletes a listed device', t => {
  const fixture = exportedTree(t);
  const devices = join(fixture.root, 'devices');
  const tool = (args, extra = {}) => spawnSync(process.execPath, [join(fixture.root, 'bin/xcrun'), ...args], {
    env: { ...process.env, ENDURAGENT_VERIFY_FAKE_ROOT: fixture.root, ...extra },
    encoding: 'utf8', timeout: 10000,
  });
  const created = tool(['simctl', 'create', 'snapshot-proof', 'fixture-type', 'fixture-runtime']);
  assert.equal(created.status, 0, created.stderr);
  const udid = created.stdout.trim();
  const removeListedDevices = join(fixture.root, 'remove-listed-devices.mjs');
  writeFileSync(removeListedDevices, `
import fs from 'node:fs';
import { join } from 'node:path';
import { syncBuiltinESMExports } from 'node:module';
const readdir = fs.readdirSync;
fs.readdirSync = (...args) => {
  const entries = readdir(...args);
  if (args[0] === process.env.VERIFY_DELETE_DURING_LIST) {
    for (const entry of entries) fs.rmSync(join(args[0], entry));
  }
  return entries;
};
syncBuiltinESMExports();
`);
  const listed = tool(['simctl', 'list', 'devices', '-j'], {
    NODE_OPTIONS: `--import=${removeListedDevices}`, VERIFY_DELETE_DURING_LIST: devices,
  });
  assert.equal(listed.status, 0, listed.stderr);
  assert.deepEqual(JSON.parse(listed.stdout), {
    devices: { fixture: [{ name: 'snapshot-proof', udid, state: 'Booted' }] },
  });
  assert.deepEqual(readdirSync(devices), []);
});

test('the real build command accepts a non-git export and an external build folder', t => {
  const fixture = exportedTree(t);
  const result = fixture.run(['build', '--build-folder', fixture.build]);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(existsSync(join(fixture.build, 'verify-ios-sources.json')));
  assert.equal(existsSync(join(fixture.tree, 'DerivedData')), false);
  assert.equal(existsSync(join(fixture.tree, '.git')), false);
  const ready = fixture.run(['doctor']);
  assert.equal(ready.status, 0, ready.stderr);
  writeFileSync(join(fixture.tree, 'apps/ios/EnduragentUITests/New.swift'), 'final class NewProof: XCTestCase {}');
  const stale = fixture.run(['doctor']);
  assert.equal(stale.status, 1, stale.stderr);
  assert.match(stale.stdout, /stale build.*New.swift/);
});

test('suite command uses the caller timing file and the requested subset', t => {
  const fixture = exportedTree(t);
  const timings = join(fixture.root, 'timings.json');
  writeFileSync(timings, JSON.stringify({ AlphaProof: 10, BravoDarkProof: 100, CharlieProof: 90 }));
  const result = fixture.run(['suite', '--shards', '2', '--timings', timings, 'AlphaProof', 'BravoDarkProof']);
  assert.equal(result.status, 0, result.stderr);
  const suite = readdirSync(fixture.runs).find(name => !name.includes('shard'));
  const plan = JSON.parse(readFileSync(join(fixture.runs, suite, 'plan.json'), 'utf8'));
  assert.deepEqual(plan.shards.map(shard => shard.proofs), [['BravoDarkProof'], ['AlphaProof']]);
  assert.deepEqual(plan.shards.map(shard => shard.estimatedSeconds), [100, 10]);
});

test('suite rejects a missing timing file before creating a simulator or building', t => {
  const fixture = exportedTree(t);
  const result = fixture.run(['suite', '--shards', '2', '--timings', join(fixture.root, 'missing.json')]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /timing file missing/);
  assert.equal(existsSync(join(fixture.root, 'devices')), false);
});

for (const [label, env, expected] of [
  ['pass', {}, 0],
  ['failure', { VERIFY_FAIL_CLASS: 'AlphaProof' }, 1],
  ['skip', { VERIFY_SKIP_CLASS: 'BravoDarkProof' }, 1],
  ['missing result', { VERIFY_MISSING_CLASS: 'AlphaProof' }, 1],
  ['boot failure', { VERIFY_FAIL_BOOT: '1' }, 1],
]) {
  test(`one suite command reports every class and deletes every owned simulator after ${label}`, t => {
    const fixture = exportedTree(t);
    const result = fixture.run(['suite', '--shards', '2'], env);
    assert.equal(result.status, expected, result.stderr);
    assert.deepEqual(readdirSync(join(fixture.root, 'devices')), []);
    const suite = readdirSync(fixture.runs).find(name => !name.includes('shard'));
    const summary = JSON.parse(readFileSync(join(fixture.runs, suite, 'summary.json'), 'utf8'));
    assert.deepEqual(summary.classes.map(row => row.name).sort(), ['AlphaProof', 'BravoDarkProof', 'CharlieProof']);
    assert.equal(summary.shards.length, 2);
    for (const shard of summary.shards) assert.ok(existsSync(join(shard.directory, 'summary.json')));
    if (label === 'skip') assert.equal(summary.classes.find(row => row.name === 'BravoDarkProof').skipped, 1);
    if (label === 'missing result') assert.equal(summary.classes.find(row => row.name === 'AlphaProof').missing, 1);
    const calls = readdirSync(fixture.root).filter(name => name.startsWith('call-')).map(name => JSON.parse(readFileSync(join(fixture.root, name), 'utf8')));
    assert.equal(calls.filter(call => call.args.includes('build-for-testing')).length, 1);
    for (const call of calls.filter(call => call.args.includes('test-without-building'))) {
      assert.equal(call.args[call.args.indexOf('-parallel-testing-enabled') + 1], 'NO');
      assert.equal(call.args[call.args.indexOf('-derivedDataPath') + 1], fixture.build);
    }
  });
}
