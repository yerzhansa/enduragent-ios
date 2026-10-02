#!/usr/bin/env node
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { closeSync, copyFileSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseOptions, planShards, proofClasses, summarizeTests } from './sim-plan.mjs';

const helper = fileURLToPath(import.meta.url);
const repo = resolve(dirname(helper), '../../../..');
const options = parseOptions(process.argv.slice(2), process.env, repo);
const runsRoot = process.env.ENDURAGENT_VERIFY_RUNS ?? join(homedir(), 'Library/Logs/enduragent-verify');
const captures = process.env.ENDURAGENT_PROTOTYPE_CAPTURES ?? join(homedir(), 'projects/enduragent/desktop/docs/prototypes/ios/captures-2026-09-25');
const deviceType = process.env.ENDURAGENT_SIM_DEVICE ?? 'iPhone 17e';
const bundleId = 'icu.enduragent.app';
const project = join(repo, 'apps/ios/Enduragent.xcodeproj');
const derivedData = options.buildFolder;
const products = join(derivedData, 'Build/Products');
const appPath = join(products, 'Debug-iphonesimulator/Enduragent.app');
const sourceManifest = join(derivedData, 'verify-ios-sources.json');
const simPrefix = 'enduragent-verify-';
const fixtureArgs = ['-EnduragentFixture', 'first-week', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'];
const statusBar = ['--time', '9:41', '--dataNetwork', 'wifi', '--wifiMode', 'active', '--wifiBars', '3', '--cellularMode', 'active', '--cellularBars', '4', '--batteryState', 'charged', '--batteryLevel', '100'];

function capture(command, args) {
  return execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 64 * 1024 * 1024 }).trim();
}
function succeeds(command, args) {
  return spawnSync(command, args, { stdio: 'ignore' }).status === 0;
}
function logged(log, command, args) {
  const fd = openSync(log, 'w');
  try {
    const { status, error } = spawnSync(command, args, { cwd: repo, stdio: ['ignore', fd, fd] });
    if (error) throw error;
    return status;
  } finally {
    closeSync(fd);
  }
}
function tail(log) {
  return readFileSync(log, 'utf8').trimEnd().split('\n').slice(-25).join('\n');
}
function pause(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}
function stamp() {
  return `${capture('date', ['+%Y-%m-%d-%H%M%S'])}-${randomUUID().slice(0, 8)}`;
}
function slug(value, what) {
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value ?? '')) throw new Error(`${what} must be kebab-case, got ${JSON.stringify(value)}`);
  return value;
}
function simName(id) {
  return `${simPrefix}${id}`;
}
function devices() {
  const listed = JSON.parse(capture('xcrun', ['simctl', 'list', 'devices', '-j'])).devices;
  return Object.values(listed).flat();
}
function findSim(id) {
  return devices().find(device => device.name === simName(id));
}
function iosRuntimes() {
  return JSON.parse(capture('xcrun', ['simctl', 'list', 'runtimes', '-j'])).runtimes
    .filter(runtime => runtime.platform === 'iOS' && runtime.isAvailable && Number(runtime.version.split('.')[0]) >= 26)
    .sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }));
}
function nativeStates() {
  return [...new Set(readdirSync(captures).filter(name => name.startsWith('native-')).map(name => name.replace(/^native-|-(?:light|dark)\.png$/g, '')))];
}
function runDir(id) {
  const dir = join(runsRoot, slug(id, 'run id'));
  if (!existsSync(join(dir, 'run.json'))) throw new Error(`unknown run ${id}; start one with: create <slug>`);
  return dir;
}
function activeRun(id) {
  const dir = runDir(id);
  const sim = findSim(id);
  if (!sim) throw new Error(`simulator ${simName(id)} is gone; its evidence stays in ${dir}`);
  return { dir, udid: sim.udid };
}
function sourceHashes() {
  const hashes = {};
  const ignored = new Set(['.build', '.swiftpm', 'DerivedData', 'build', 'node_modules', 'Enduragent.xcodeproj']);
  function walk(folder) {
    for (const entry of readdirSync(folder, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const path = join(folder, entry.name);
      if (ignored.has(entry.name) || path === derivedData) continue;
      if (entry.isDirectory()) walk(path);
      else if (entry.isFile()) hashes[relative(repo, path)] = createHash('sha256').update(readFileSync(path)).digest('hex');
      else throw new Error(`source must be a regular file or directory: ${path}`);
    }
  }
  walk(join(repo, 'apps/ios'));
  return hashes;
}
function staleSource() {
  if (!existsSync(sourceManifest)) return 'no source manifest from sim.mjs build';
  const built = JSON.parse(readFileSync(sourceManifest, 'utf8'));
  const current = sourceHashes();
  const files = [...new Set([...Object.keys(built), ...Object.keys(current)])].sort();
  const changed = files.find(file => built[file] !== current[file]);
  return changed ? `${changed} differs from the last build` : undefined;
}

function doctor(id) {
  const lines = [];
  let failed = false;
  const check = (ok, text) => {
    failed ||= !ok;
    lines.push(`${ok ? 'ok  ' : 'FAIL'} ${text}`);
  };
  const xcode = capture('xcodebuild', ['-version']).split('\n')[0];
  check(Number(xcode.replace('Xcode ', '').split('.')[0]) >= 26, xcode);
  const runtime = iosRuntimes()[0];
  check(Boolean(runtime), runtime ? `runtime ${runtime.name}` : 'no available iOS 26 simulator runtime');
  const types = JSON.parse(capture('xcrun', ['simctl', 'list', 'devicetypes', '-j'])).devicetypes.map(type => type.name);
  check(types.includes(deviceType), `device type ${deviceType}`);
  check(succeeds('xcodegen', ['--version']), 'xcodegen on PATH');
  const built = existsSync(join(appPath, 'Info.plist'));
  check(built, `app build at ${appPath}`);
  if (built) {
    const identifier = capture('plutil', ['-extract', 'CFBundleIdentifier', 'raw', join(appPath, 'Info.plist')]);
    check(identifier === bundleId, `bundle id ${identifier}`);
    const stale = staleSource();
    check(!stale, stale ? `stale build: ${stale}; run build` : 'build matches the content of every source under apps/ios');
  }
  check(existsSync(products) && readdirSync(products).some(name => name.endsWith('.xctestrun')), 'UI test runner built (.xctestrun)');
  lines.push(`${existsSync(captures) ? 'ok  ' : 'note'} prototype captures at ${captures}`);
  for (const device of devices().filter(item => item.name.startsWith(simPrefix))) lines.push(`note verify simulator ${device.name} ${device.udid} ${device.state}`);
  if (id) {
    check(existsSync(join(runsRoot, slug(id, 'run id'), 'run.json')), `run ${id} evidence at ${join(runsRoot, id)}`);
    const sim = findSim(id);
    check(sim?.state === 'Booted', `simulator ${simName(id)} ${sim ? `${sim.udid} ${sim.state}` : 'missing'}`);
    if (sim?.state === 'Booted') {
      check(succeeds('xcrun', ['simctl', 'get_app_container', sim.udid, bundleId]), `${bundleId} installed`);
      const running = capture('xcrun', ['simctl', 'spawn', sim.udid, 'launchctl', 'list']).includes(`UIKitApplication:${bundleId}`);
      lines.push(`note ${bundleId} ${running ? 'running' : 'not running'}`);
    }
  }
  console.log(lines.join('\n'));
  process.exitCode = failed ? 1 : 0;
}

function build() {
  capture('xcodegen', ['generate', '--spec', join(repo, 'apps/ios/project.yml')]);
  mkdirSync(derivedData, { recursive: true });
  const log = join(derivedData, 'verify-ios-build.log');
  const hashes = sourceHashes();
  const status = logged(log, 'xcodebuild', ['build-for-testing', '-project', project, '-scheme', 'Enduragent', '-configuration', 'Debug', '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', derivedData, 'CODE_SIGNING_ALLOWED=NO']);
  if (status !== 0) throw new Error(`build-for-testing exited ${status}; log ${log}\n${tail(log)}`);
  writeFileSync(sourceManifest, `${JSON.stringify(hashes, null, 2)}\n`);
  console.log(`built ${appPath}\nlog ${log}`);
}

function create(name) {
  createRun(`${stamp()}-${slug(name, 'run slug')}`);
}

function createRun(id) {
  const dir = join(runsRoot, id);
  if (existsSync(dir) || findSim(id)) throw new Error(`run ${id} already exists`);
  const runtime = iosRuntimes()[0];
  if (!runtime) throw new Error('no available iOS 26 simulator runtime; install one in Xcode > Settings > Components');
  mkdirSync(dir, { recursive: true });
  const revision = process.env.ENDURAGENT_VERIFY_REVISION ?? (existsSync(join(repo, '.git')) ? capture('git', ['-C', repo, 'describe', '--always', '--dirty']) : 'exported-tree');
  const record = { id, simulator: simName(id), deviceType, runtime: runtime.name, checkout: repo, revision, buildFolder: derivedData, sourceDigest: createHash('sha256').update(JSON.stringify(sourceHashes())).digest('hex') };
  writeFileSync(join(dir, 'run.json'), `${JSON.stringify(record, null, 2)}\n`);
  const udid = capture('xcrun', ['simctl', 'create', simName(id), deviceType, runtime.identifier]);
  writeFileSync(join(dir, 'run.json'), `${JSON.stringify({ ...record, udid }, null, 2)}\n`);
  try {
    capture('xcrun', ['simctl', 'bootstatus', udid, '-b']);
    capture('xcrun', ['simctl', 'status_bar', udid, 'override', ...statusBar]);
    capture('xcrun', ['simctl', 'ui', udid, 'appearance', 'light']);
  } catch (error) {
    cleanup(id);
    throw error;
  }
  console.log(`run ${id}\nsimulator ${simName(id)} ${udid}\nevidence ${dir}`);
}

function install(id) {
  const { udid } = activeRun(id);
  if (!existsSync(appPath)) throw new Error(`no build at ${appPath}; run build first`);
  capture('xcrun', ['simctl', 'install', udid, appPath]);
  console.log(`installed ${bundleId} on ${udid}`);
}

function launch(id, ...extra) {
  const { udid } = activeRun(id);
  const keep = extra.includes('--keep');
  const passthrough = extra.filter(argument => argument !== '--keep');
  const storeArgs = ['-EnduragentFixtureStore', keep ? 'keep' : 'fresh'];
  console.log(capture('xcrun', ['simctl', 'launch', '--terminate-running-process', udid, bundleId, ...fixtureArgs, ...storeArgs, ...passthrough]));
}

function shot(id, label) {
  const { dir, udid } = activeRun(id);
  const path = join(dir, `${slug(label, 'label')}.png`);
  if (existsSync(path)) throw new Error(`${path} exists; evidence is never overwritten`);
  capture('xcrun', ['simctl', 'io', udid, 'screenshot', '--type=png', path]);
  console.log(path);
}

function test(id, ...proofs) {
  if (proofs.length === 0) throw new Error('test needs at least one proof, for example: test <run> FirstConversationProof');
  const { dir, udid } = activeRun(id);
  const dark = proofs.filter(proof => /DarkProof(\/|$)/.test(proof));
  const light = proofs.filter(proof => !dark.includes(proof));
  const failures = [];
  const classes = [];
  if (light.length > 0) {
    capture('xcrun', ['simctl', 'ui', udid, 'appearance', 'light']);
    const report = runProofs(dir, udid, light);
    failures.push(...report.failures);
    classes.push(...report.classes);
  }
  if (dark.length > 0) {
    capture('xcrun', ['simctl', 'ui', udid, 'appearance', 'dark']);
    try {
      const report = runProofs(dir, udid, dark);
      failures.push(...report.failures);
      classes.push(...report.classes);
    } finally {
      capture('xcrun', ['simctl', 'ui', udid, 'appearance', 'light']);
    }
  }
  return { classes, failures };
}

function runProofs(dir, udid, proofs) {
  spawnSync('xcrun', ['simctl', 'terminate', udid, bundleId], { stdio: 'ignore' });
  const name = `uitest-${stamp()}`;
  const bundle = join(dir, `${name}.xcresult`);
  const log = join(dir, `${name}.log`);
  const status = logged(log, 'xcodebuild', ['test-without-building', '-project', project, '-scheme', 'Enduragent', '-destination', `id=${udid}`, '-derivedDataPath', derivedData, '-parallel-testing-enabled', 'NO', '-resultBundlePath', bundle, ...proofs.map(proof => `-only-testing:EnduragentUITests/${proof}`)]);
  const failures = status === 0 ? [] : [`test-without-building exited ${status}\n${tail(log)}`];
  let classes = summarizeTests({ testNodes: [] }, [...new Set(proofs.map(proof => proof.split('/')[0]))]);
  if (existsSync(bundle)) {
    const tests = capture('xcrun', ['xcresulttool', 'get', 'test-results', 'tests', '--path', bundle]);
    writeFileSync(join(dir, `${name}-tests.json`), `${tests}\n`);
    classes = summarizeTests(JSON.parse(tests), classes.map(row => row.name));
    writeFileSync(join(dir, `${name}-classes.json`), `${JSON.stringify(classes, null, 2)}\n`);
    const attachments = join(dir, `${name}-attachments`);
    mkdirSync(attachments, { recursive: true });
    capture('xcrun', ['xcresulttool', 'export', 'attachments', '--path', bundle, '--output-path', attachments]);
    const summary = capture('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', bundle]);
    writeFileSync(join(dir, `${name}-summary.json`), `${summary}\n`);
    const { result, passedTests, failedTests, skippedTests } = JSON.parse(summary);
    console.log(`${result}: ${passedTests} passed, ${failedTests} failed, ${skippedTests} skipped`);
    for (const { testIdentifier, attachments: items } of JSON.parse(readFileSync(join(attachments, 'manifest.json'), 'utf8'))) {
      for (const item of items) console.log(`attachment ${testIdentifier} ${item.suggestedHumanReadableName.replace(/_\d+_[0-9A-F-]{36}(?=\.\w+$)/, '')} ${join(attachments, item.exportedFileName)}`);
    }
  }
  for (const row of classes) {
    if (row.failed || row.skipped || row.missing) failures.push(`${row.name}: ${row.failed} failed, ${row.skipped} skipped, ${row.missing} missing`);
  }
  console.log(`result bundle ${bundle}\nlog ${log}`);
  return { classes, failures };
}

function parity(id, state, theme, flag, source) {
  if (!['light', 'dark'].includes(theme)) throw new Error('parity needs a theme: light or dark');
  if (flag !== undefined && (flag !== '--from' || !source)) throw new Error('parity takes an optional --from <png>');
  const prototype = join(captures, `native-${slug(state, 'state')}-${theme}.png`);
  if (!existsSync(prototype)) throw new Error(`no prototype capture ${prototype}\nstates: ${nativeStates().join(' ')}`);
  const { dir, udid } = activeRun(id);
  const out = join(dir, 'parity', `${state}-${theme}`);
  if (existsSync(out)) throw new Error(`${out} exists; evidence is never overwritten`);
  mkdirSync(out, { recursive: true });
  const simulator = join(out, 'simulator.png');
  if (source) {
    copyFileSync(source, simulator);
  } else {
    capture('xcrun', ['simctl', 'ui', udid, 'appearance', theme]);
    pause(1500);
    capture('xcrun', ['simctl', 'io', udid, 'screenshot', '--type=png', simulator]);
  }
  capture('sips', ['--resampleWidth', '390', simulator, '--out', join(out, 'simulator-390.png')]);
  copyFileSync(prototype, join(out, 'prototype.png'));
  console.log(out);
}

function cleanup(id) {
  const dir = runDir(id);
  const sim = findSim(id);
  if (sim) {
    try {
      if (sim.state !== 'Shutdown') capture('xcrun', ['simctl', 'shutdown', sim.udid]);
    } finally {
      capture('xcrun', ['simctl', 'delete', sim.udid]);
    }
    console.log(`deleted ${simName(id)} ${sim.udid}`);
  } else {
    console.log(`no simulator ${simName(id)}; nothing to delete`);
  }
  if (findSim(id)) throw new Error(`${simName(id)} still exists after delete`);
  console.log(`evidence kept at ${dir}\n${readdirSync(dir).sort().join('\n')}`);
}

function shard(id, ...proofs) {
  const dir = join(runsRoot, slug(id, 'shard id'));
  const report = { classes: summarizeTests({ testNodes: [] }, proofs), failures: [] };
  try {
    createRun(id);
    install(id);
    Object.assign(report, test(id, ...proofs));
  } catch (error) {
    report.failures.push(error.message);
  } finally {
    if (existsSync(join(dir, 'run.json'))) {
      try {
        cleanup(id);
      } catch (error) {
        report.failures.push(`cleanup: ${error.message}`);
      }
    }
    if (existsSync(dir)) {
      const measured = readdirSync(dir).filter(file => file.endsWith('-classes.json')).flatMap(file => JSON.parse(readFileSync(join(dir, file), 'utf8')));
      report.classes = report.classes.map(row => measured.find(result => result.name === row.name) ?? row);
    }
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'summary.json'), `${JSON.stringify(report, null, 2)}\n`);
  }
  if (report.failures.length) throw new Error(report.failures.join('\n'));
}

function runShard(log, id, proofs) {
  return new Promise(resolveStatus => {
    const fd = openSync(log, 'w');
    const child = spawn(process.execPath, [helper, 'shard', id, ...proofs], {
      cwd: repo,
      env: { ...process.env, ENDURAGENT_VERIFY_BUILD: derivedData },
      stdio: ['ignore', fd, fd],
    });
    child.on('error', error => console.error(`shard ${id}: ${error.message}`));
    child.on('close', (status, signal) => {
      closeSync(fd);
      resolveStatus({ status, signal });
    });
  });
}

async function suite(...requested) {
  const available = proofClasses(repo);
  const proofs = requested.length ? requested : available;
  for (const proof of proofs) {
    if (!available.includes(proof)) throw new Error(`unknown UI proof class ${proof}`);
  }
  const timingFile = options.timings ?? join(runsRoot, 'timings.json');
  if (options.timings && !existsSync(timingFile)) throw new Error(`timing file missing: ${timingFile}`);
  const timings = existsSync(timingFile) ? JSON.parse(readFileSync(timingFile, 'utf8')) : {};
  const plan = planShards(proofs, options.shards, timings);
  const id = `${stamp()}-suite`;
  const dir = join(runsRoot, id);
  mkdirSync(dir, { recursive: true });
  const shards = plan.map((item, index) => ({
    ...item, id: `${id}-shard-${index + 1}`, directory: join(runsRoot, `${id}-shard-${index + 1}`),
    log: join(dir, `shard-${index + 1}.log`),
  }));
  writeFileSync(join(dir, 'plan.json'), `${JSON.stringify({ buildFolder: derivedData, timingFile, shards }, null, 2)}\n`);
  build();
  const statuses = await Promise.allSettled(shards.map(item => runShard(item.log, item.id, item.proofs)));
  const reports = shards.map((item, index) => {
    const file = join(item.directory, 'summary.json');
    let report = { classes: summarizeTests({ testNodes: [] }, item.proofs), failures: ['shard wrote no summary'] };
    try {
      if (existsSync(join(item.directory, 'run.json')) && findSim(item.id)) cleanup(item.id);
      if (existsSync(file)) report = JSON.parse(readFileSync(file, 'utf8'));
    } catch (error) {
      report.failures.push(error.message);
    }
    const outcome = statuses[index];
    if (outcome.status === 'rejected') report.failures.push(outcome.reason.message);
    else if (outcome.value.status !== 0) report.failures.push(`shard exited ${outcome.value.status}, signal ${outcome.value.signal}`);
    mkdirSync(item.directory, { recursive: true });
    writeFileSync(file, `${JSON.stringify(report, null, 2)}\n`);
    return { ...item, ...report };
  });
  const classes = reports.flatMap(report => report.classes).sort((a, b) => a.name.localeCompare(b.name));
  const failed = reports.some(report => report.failures.length) || classes.some(row => row.failed || row.skipped || row.missing);
  const summary = { result: failed ? 'Failed' : 'Passed', classes, shards: reports };
  writeFileSync(join(dir, 'summary.json'), `${JSON.stringify(summary, null, 2)}\n`);
  const lines = ['| Class | Passed | Failed | Skipped | Missing | Seconds |', '| --- | --- | --- | --- | --- | --- |',
    ...classes.map(row => `| ${row.name} | ${row.passed} | ${row.failed} | ${row.skipped} | ${row.missing} | ${row.seconds.toFixed(1)} |`)];
  writeFileSync(join(dir, 'summary.md'), `${summary.result}\n\n${lines.join('\n')}\n`);
  const measured = Object.fromEntries(classes.filter(row => row.passed && !row.failed && !row.skipped && !row.missing && row.seconds > 0).map(row => [row.name, row.seconds]));
  writeFileSync(join(dir, 'timings.json'), `${JSON.stringify({ ...timings, ...measured }, null, 2)}\n`);
  console.log(`${summary.result}\ncombined summary ${join(dir, 'summary.md')}\ntimings ${join(dir, 'timings.json')}`);
  if (failed) throw new Error(`proof suite failed; see ${join(dir, 'summary.json')}`);
}

const commands = { doctor, build, create, install, launch, shot, test, suite, shard, parity, cleanup };
const { command, args: rest } = options;
if (!Object.hasOwn(commands, command ?? '')) {
  console.error(`Usage: sim.mjs <${Object.keys(commands).join('|')}> [arguments]`);
  process.exit(2);
}
try {
  const report = await commands[command](...rest);
  if (report?.failures?.length) throw new Error(report.failures.join('\n'));
} catch (error) {
  console.error(`sim.mjs ${command}: ${error.message}`);
  process.exitCode = 1;
}
