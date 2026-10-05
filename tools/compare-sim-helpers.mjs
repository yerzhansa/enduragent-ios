#!/usr/bin/env node
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { planShards } from '../.agents/skills/verify-ios/helpers/sim-plan.mjs';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const plansFile = join(repo, 'tools/Tests/SimTests/Fixtures/plans.json');
const mode = process.argv[2] ?? 'compare';
if (!['compare', 'write-plans'].includes(mode) || process.argv.length > 4) {
  console.error('Usage: node tools/compare-sim-helpers.mjs [compare [node|swift] | write-plans]');
  process.exit(2);
}
const fixtureKind = process.argv[3] ?? 'node';

function planCases() {
  let seed = 20261005;
  const random = bound => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return (seed >>> 8) % bound;
  };
  const names = ['AlphaProof', 'alphaProof', 'ALPHAProof', 'Alpha_Proof', 'Alpha2Proof', 'Alpha10Proof', 'BravoProof', 'BravoDarkProof', 'bravoProof', 'CharlieProof', '_HiddenProof', 'Zulu9Proof', 'zuluProof', 'DeltaProof', 'EchoProof', 'EchoDarkProof', 'FoxtrotProof', 'GolfProof', 'HotelProof', 'IndiaProof'];
  const seconds = [1, 7, 7, 7.5, 0.1, 0.2, 0.30000000000000004, 12.25, 12.75, 100, 295.5580669641495, 68.381511926651, 1e-7, 1e21, 452.8981922864914, 3];
  const cases = [];
  for (let index = 0; index < 200; index++) {
    const proofs = [...names].sort(() => random(3) - 1).slice(0, 1 + random(names.length));
    const timings = {};
    if (random(4) > 0) {
      for (const name of [...proofs, 'RetiredProof', 'OtherProof'].filter(() => random(3) > 0)) timings[name] = seconds[random(seconds.length)];
    }
    cases.push({ proofs, shards: 1 + random(Math.min(6, proofs.length)), timings });
  }
  cases.push(
    { proofs: ['AlphaProof', 'AlphaProof'], shards: 1, timings: {} },
    { proofs: ['AlphaProof'], shards: 2, timings: {} },
    { proofs: ['AlphaProof'], shards: 0, timings: {} },
    { proofs: ['AlphaProof/testOne'], shards: 1, timings: {} },
    { proofs: ['Alpha Proof'], shards: 1, timings: {} },
    { proofs: ['AlphaProof'], shards: 1, timings: { AlphaProof: -1 } },
    { proofs: ['AlphaProof'], shards: 1, timings: { OtherProof: 0 } },
    { proofs: ['AlphaProof'], shards: 1, timings: { AlphaProof: '7' } },
    { proofs: ['AlphaProof'], shards: 1, timings: { AlphaProof: null } },
    { proofs: ['AlphaProof'], shards: 1, timings: [7] },
    { proofs: ['AlphaProof'], shards: 1, timings: null },
    { proofs: ['AlphaProof'], shards: 1, timings: 7 },
    { proofs: ['AlphaProof', 'BravoProof'], shards: 2, timings: { 10: 4, 2: 6, BravoProof: 5 } },
  );
  return cases.map(input => {
    try {
      return { ...input, plan: planShards(input.proofs, input.shards, input.timings) };
    } catch (error) {
      return { ...input, error: error.message };
    }
  });
}

const plans = `[\n${planCases().map(item => JSON.stringify(item)).join(',\n')}\n]\n`;
if (mode === 'write-plans') {
  mkdirSync(dirname(plansFile), { recursive: true });
  writeFileSync(plansFile, plans);
  console.log(`wrote ${plansFile}`);
  process.exit(0);
}

let differences = 0;
function report(name, same, detail = '') {
  console.log(`${same ? 'same' : 'DIFFERENT'}  ${name}${detail ? `\n${detail}` : ''}`);
  if (!same) differences++;
}

report('run plans: sim-plan.mjs output equals tools/Tests/SimTests/Fixtures/plans.json, which the Swift suite checks the Swift planner against', existsSync(plansFile) && readFileSync(plansFile, 'utf8') === plans);

const bin = execFileSync('swift', ['build', '--package-path', join(repo, 'tools'), '--show-bin-path'], { encoding: 'utf8' }).trim();
execFileSync('swift', ['build', '--package-path', join(repo, 'tools'), '--product', 'sim'], { stdio: ['ignore', 'inherit', 'inherit'] });
if (fixtureKind === 'swift') execFileSync('swift', ['build', '--package-path', join(repo, 'tools'), '--product', 'SimFixtureTool'], { stdio: ['ignore', 'inherit', 'inherit'] });

const work = mkdtempSync(join(tmpdir(), 'enduragent-sim-compare-'));
const tree = join(work, 'tree');
mkdirSync(tree);
const archive = join(work, 'tree.tar');
execFileSync('git', ['-C', repo, 'archive', '--output', archive, 'HEAD', 'apps/ios', '.agents/skills/verify-ios/helpers']);
execFileSync('tar', ['-x', '-f', archive, '-C', tree]);
mkdirSync(join(tree, 'tools/.build/debug'), { recursive: true });
copyFileSync(join(bin, 'sim'), join(tree, 'tools/.build/debug/sim'));
chmodSync(join(tree, 'tools/.build/debug/sim'), 0o755);
const captures = join(work, 'captures');
mkdirSync(captures);
for (const name of ['native-first-run-light.png', 'native-first-run-dark.png', 'native-credits-light.png']) writeFileSync(join(captures, name), name);
const screenshot = join(work, 'screenshot.png');
writeFileSync(screenshot, 'screenshot');

const sides = {
  node: [process.execPath, join(tree, '.agents/skills/verify-ios/helpers/sim.mjs')],
  swift: [join(tree, 'tools/.build/debug/sim')],
};
let scenarioCount = 0;

function scenario(name, steps, { environment = {}, setup = () => {} } = {}) {
  const index = ++scenarioCount;
  const dumps = {};
  for (const side of ['node', 'swift']) {
    const root = join(work, `${String(index).padStart(2, '0')}-${side}`);
    const paths = { root, fake: join(root, 'fake'), runs: join(root, 'runs'), build: join(root, 'build'), bin: join(root, 'bin'), slow: join(root, 'slow'), cwd: join(root, 'cwd') };
    for (const folder of [paths.root, paths.fake, paths.bin, paths.slow, paths.cwd]) mkdirSync(folder);
    for (const tool of ['git', 'xcrun', 'xcodegen', 'xcodebuild', 'plutil', 'sips']) {
      const fake = join(tool === 'xcodebuild' ? paths.slow : paths.bin, tool);
      if (fixtureKind === 'swift') {
        symlinkSync(join(bin, 'SimFixtureTool'), fake);
      } else {
        writeFileSync(fake, readFileSync(join(repo, 'tools/fixtures/verify-ios-tool.mjs'), 'utf8').replace(/^#![^\n]+/, `#!${process.execPath}`));
        chmodSync(fake, 0o755);
      }
    }
    writeFileSync(join(paths.bin, 'xcodebuild'), `#!/bin/sh\ncase "$*" in *test-without-building*) /bin/sleep 1.1 ;; esac\nexec "${join(paths.slow, 'xcodebuild')}" "$@"\n`);
    chmodSync(join(paths.bin, 'xcodebuild'), 0o755);
    symlinkSync('/bin/date', join(paths.bin, 'date'));
    const env = { HOME: paths.root, PATH: paths.bin, ENDURAGENT_VERIFY_FAKE_ROOT: paths.fake, ENDURAGENT_VERIFY_RUNS: paths.runs, ENDURAGENT_VERIFY_BUILD: paths.build, ENDURAGENT_PROTOTYPE_CAPTURES: captures, ...environment };
    setup(paths);
    const streams = [];
    const results = [];
    let run;
    for (const step of steps) {
      const args = step.args({ ...paths, run });
      const result = spawnSync(sides[side][0], [...sides[side].slice(1), ...args], { cwd: paths.cwd, env: { ...env, ...step.environment }, encoding: 'utf8', timeout: 300000 });
      assert.equal(result.error, undefined, `${name}: ${side} ${args.join(' ')}`);
      run ??= /^run (\S+)$/m.exec(result.stdout)?.[1];
      const errors = step.looseErrors ? (result.stderr.includes(step.looseErrors) ? `contains: ${step.looseErrors}` : result.stderr) : result.stderr;
      streams.push(result.stdout, errors);
      results.push({ args: args.join(' '), status: result.status, signal: result.signal, stdout: result.stdout, stderr: errors });
      step.after?.(paths);
    }
    dumps[side] = dump(paths, streams, results);
    writeFileSync(join(root, 'compared.txt'), dumps[side]);
  }
  const same = dumps.node === dumps.swift;
  report(name, same, same ? '' : firstDifference(dumps.node, dumps.swift));
}

function files(folder, prefix = '') {
  if (!existsSync(folder)) return [];
  return readdirSync(folder).sort().flatMap(name => {
    const path = join(folder, name);
    const status = lstatSync(path);
    if (status.isDirectory()) return [[`${prefix}${name}/`, ''], ...files(path, `${prefix}${name}/`)];
    return [[`${prefix}${name}`, readFileSync(path, 'utf8')]];
  });
}

function dump(paths, streams, results) {
  const runs = files(paths.runs, 'runs/');
  const shardLogs = runs.filter(([name]) => /-suite\/shard-\d+\.log$/.test(name)).map(([, content]) => content);
  const volatile = new Map();
  const normalize = text => text
    .replaceAll(paths.root, '<side>')
    .replaceAll(tree, '<tree>')
    .replace(/\d{4}-\d{2}-\d{2}-\d{6}-[0-9a-f]{8}/g, stamp => volatile.get(stamp) ?? volatile.set(stamp, `<stamp ${volatile.size + 1}>`).get(stamp))
    .replace(/fixture-\d+/g, udid => volatile.get(udid) ?? volatile.set(udid, `<device ${volatile.size + 1}>`).get(udid))
    .replaceAll('sim.mjs', 'sim');
  for (const stream of [...streams, ...shardLogs]) normalize(stream);
  const calls = files(paths.fake).filter(([name]) => name.startsWith('call-')).map(([, content]) => JSON.parse(content)).filter(call => call.command !== 'date').map(call => normalize(`${call.command} ${call.args.join(' ')}`));
  const ordered = results.some(result => result.args.startsWith('suite')) ? [...calls].sort() : calls;
  const sections = [
    ...results.map(result => `$ ${normalize(result.args)}\nstatus ${result.status} signal ${result.signal}\n--- stdout\n${normalize(result.stdout)}--- stderr\n${normalize(result.stderr)}`),
    `--- calls\n${ordered.join('\n')}`,
    ...[...runs, ...files(paths.build, 'build/')].map(([name, content]) => [normalize(name), normalize(content)]).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([name, content]) => `--- ${name}\n${content}`),
  ];
  return sections.join('\n');
}

function firstDifference(node, swift) {
  const left = node.split('\n');
  const right = swift.split('\n');
  const index = left.findIndex((line, position) => line !== right[position]);
  const at = index === -1 ? left.length : index;
  return [`  first difference at line ${at + 1}`, ...left.slice(Math.max(0, at - 3), at + 4).map(line => `  node  | ${line}`), ...right.slice(Math.max(0, at - 3), at + 4).map(line => `  swift | ${line}`)].join('\n');
}

const step = (args, extra = {}) => ({ args: typeof args === 'function' ? args : () => args, ...extra });
const added = join(tree, 'apps/ios/EnduragentUITests/Added.swift');
const suiteProofs = ['FirstConversationProof', 'ConfirmedPreviewProof', 'DisconnectDarkProof', 'CreditsProof', 'HistoryListProof'];

scenario('build, doctor, a doctor for a missing device type and a stale build, and the usage line', [
  step(paths => ['build', '--build-folder', paths.build]),
  step(['doctor']),
  step(['doctor'], { environment: { ENDURAGENT_SIM_DEVICE: 'iPhone 99' }, after: () => writeFileSync(added, 'final class AddedProof: XCTestCase {}') }),
  step(['doctor'], { after: () => unlinkSync(added) }),
  step([]),
  step(['unknown']),
]);
scenario('one run from create to cleanup, with light and dark classes and one test method', [
  step(['build']),
  step(['create', 'smoke-check']),
  step(paths => ['doctor', paths.run]),
  step(paths => ['install', paths.run]),
  step(paths => ['launch', paths.run]),
  step(paths => ['launch', paths.run, '--keep', '-EnduragentFixtureReply', 'slow']),
  step(paths => ['shot', paths.run, 'first-screen']),
  step(paths => ['shot', paths.run, 'Not A Label']),
  step(paths => ['test', paths.run, 'FirstConversationProof']),
  step(paths => ['test', paths.run, 'DisconnectDarkProof', 'CreditsProof', 'ConfirmedPreviewProof/testConfirmedPreview']),
  step(paths => ['test', paths.run]),
  step(paths => ['parity', paths.run, 'first-run', 'light', '--from', screenshot]),
  step(paths => ['parity', paths.run, 'first-run', 'dark']),
  step(paths => ['parity', paths.run, 'first-run', 'dark']),
  step(paths => ['parity', paths.run, 'missing-state', 'light']),
  step(paths => ['parity', paths.run, 'first-run', 'sepia']),
  step(paths => ['cleanup', paths.run]),
  step(paths => ['cleanup', paths.run]),
  step(paths => ['test', paths.run, 'FirstConversationProof']),
  step(['install', 'never-created']),
  step(['cleanup']),
], { environment: { ENDURAGENT_VERIFY_REVISION: 'compared-revision' } });
scenario('a failing, a skipped and a missing class in one test command', [
  step(['build']),
  step(['create', 'unverified']),
  step(paths => ['install', paths.run]),
  step(paths => ['test', paths.run, 'FirstConversationProof', 'CreditsProof', 'HistoryListProof', 'DisconnectDarkProof']),
  step(paths => ['cleanup', paths.run]),
], { environment: { VERIFY_FAIL_CLASS: 'CreditsProof', VERIFY_SKIP_CLASS: 'HistoryListProof', VERIFY_MISSING_CLASS: 'DisconnectDarkProof' } });
scenario('install without a build, and create when the simulator does not boot', [
  step(['create', 'no-build']),
  step(paths => ['install', paths.run]),
  step(paths => ['cleanup', paths.run]),
  step(['create', 'shard-2'], { environment: { VERIFY_FAIL_BOOT: '1' } }),
]);
scenario('the whole suite on two shards with no timing file', [step(['suite', '--shards', '2'])]);
scenario('a suite subset on three shards with a timing file', [
  step(paths => ['suite', '--shards', '3', '--timings', join(paths.root, 'timings.json'), ...suiteProofs]),
], { setup: paths => writeFileSync(join(paths.root, 'timings.json'), JSON.stringify({ FirstConversationProof: 132.7092159986496, ConfirmedPreviewProof: 79.31741392612457, RetiredProof: 349.64532995224, CreditsProof: 79.31741392612457 })) });
scenario('a suite that picks up timings.json from the runs folder', [
  step(['suite', '--shards', '2', ...suiteProofs]),
], { setup: paths => { mkdirSync(paths.runs); writeFileSync(join(paths.runs, 'timings.json'), JSON.stringify({ CreditsProof: 12.25, HistoryListProof: 12.75, DisconnectDarkProof: 0.5 })); } });
for (const [label, environment] of [
  ['a failing class', { VERIFY_FAIL_CLASS: 'CreditsProof' }],
  ['a skipped class', { VERIFY_SKIP_CLASS: 'DisconnectDarkProof' }],
  ['a class with no result', { VERIFY_MISSING_CLASS: 'FirstConversationProof' }],
  ['a simulator that does not boot', { VERIFY_FAIL_BOOT: '1' }],
]) {
  scenario(`a suite with ${label}`, [step(['suite', '--shards', '2', '--build-folder', 'relative-build', ...suiteProofs])], { environment });
}
scenario('suite arguments that are refused', [
  step(paths => ['suite', '--shards', '2', '--timings', join(paths.root, 'missing.json')]),
  step(['suite', 'NoSuchProof']),
  step(['suite', 'FirstConversationProof', 'FirstConversationProof']),
  step(['suite', '--shards', '3', 'FirstConversationProof', 'CreditsProof']),
  step(paths => ['suite', '--timings', join(paths.root, 'bad-timings.json'), 'FirstConversationProof']),
  step(['suite', '--shards', '0'], { looseErrors: '--shards must be a positive whole number' }),
  step(['suite', '--shards', '1.5'], { looseErrors: '--shards must be a positive whole number' }),
  step(['suite', '--timings'], { looseErrors: '--timings needs a value' }),
  step(['build', '--build-folder', '--shards'], { looseErrors: '--build-folder needs a value' }),
], { setup: paths => writeFileSync(join(paths.root, 'bad-timings.json'), JSON.stringify({ FirstConversationProof: 0 })) });

console.log(`work folder kept at ${work}`);
if (differences) {
  console.error(`${differences} differences between the Node helper and the Swift helper`);
  process.exit(1);
}
console.log(`the Swift helper matches the Node helper in ${scenarioCount} scenarios and in the run plans, with the ${fixtureKind} fake tools`);
