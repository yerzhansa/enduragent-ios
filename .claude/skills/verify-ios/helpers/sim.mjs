#!/usr/bin/env node
import { execFileSync, spawnSync } from 'node:child_process';
import { closeSync, copyFileSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = capture('git', ['-C', dirname(fileURLToPath(import.meta.url)), 'rev-parse', '--show-toplevel']);
const runsRoot = process.env.ENDURAGENT_VERIFY_RUNS ?? join(homedir(), 'Library/Logs/enduragent-verify');
const captures = process.env.ENDURAGENT_PROTOTYPE_CAPTURES ?? join(homedir(), 'projects/enduragent/desktop/docs/prototypes/ios/captures-2026-09-25');
const deviceType = process.env.ENDURAGENT_SIM_DEVICE ?? 'iPhone 17e';
const bundleId = 'icu.enduragent.app';
const project = join(repo, 'apps/ios/Enduragent.xcodeproj');
const derivedData = join(repo, 'DerivedData');
const products = join(derivedData, 'Build/Products');
const appPath = join(products, 'Debug-iphonesimulator/Enduragent.app');
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
  const { status } = spawnSync(command, args, { stdio: ['ignore', fd, fd] });
  closeSync(fd);
  return status;
}
function tail(log) {
  return readFileSync(log, 'utf8').trimEnd().split('\n').slice(-25).join('\n');
}
function pause(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}
function stamp() {
  const now = new Date();
  const pad = value => String(value).padStart(2, '0');
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
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
function newestMtime(paths) {
  return paths.reduce((newest, path) => (existsSync(path) ? Math.max(newest, statSync(path).mtimeMs) : newest), 0);
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
    const sources = capture('git', ['-C', repo, 'ls-files', '--cached', '--others', '--exclude-standard', '--', 'apps/ios', ':!apps/ios/Enduragent.xcodeproj']).split('\n').filter(Boolean);
    const newest = sources.map(file => ({ file, time: newestMtime([join(repo, file)]) })).reduce((best, item) => (item.time > best.time ? item : best), { file: '', time: 0 });
    const builtAt = newestMtime([appPath, ...readdirSync(appPath).map(name => join(appPath, name))]);
    check(builtAt >= newest.time, builtAt >= newest.time ? 'build is newer than every source under apps/ios' : `stale build: ${newest.file} changed after the last build; run build`);
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
  const status = logged(log, 'xcodebuild', ['build-for-testing', '-project', project, '-scheme', 'Enduragent', '-configuration', 'Debug', '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', derivedData, 'CODE_SIGNING_ALLOWED=NO']);
  if (status !== 0) throw new Error(`build-for-testing exited ${status}; log ${log}\n${tail(log)}`);
  console.log(`built ${appPath}\nlog ${log}`);
}

function create(name) {
  const id = `${stamp()}-${slug(name, 'run slug')}`;
  const dir = join(runsRoot, id);
  if (existsSync(dir) || findSim(id)) throw new Error(`run ${id} already exists`);
  const runtime = iosRuntimes()[0];
  if (!runtime) throw new Error('no available iOS 26 simulator runtime; install one in Xcode > Settings > Components');
  mkdirSync(dir, { recursive: true });
  const record = { id, simulator: simName(id), deviceType, runtime: runtime.name, checkout: repo, revision: capture('git', ['-C', repo, 'describe', '--always', '--dirty']) };
  writeFileSync(join(dir, 'run.json'), `${JSON.stringify(record, null, 2)}\n`);
  const udid = capture('xcrun', ['simctl', 'create', simName(id), deviceType, runtime.identifier]);
  writeFileSync(join(dir, 'run.json'), `${JSON.stringify({ ...record, udid }, null, 2)}\n`);
  capture('xcrun', ['simctl', 'bootstatus', udid, '-b']);
  capture('xcrun', ['simctl', 'status_bar', udid, 'override', ...statusBar]);
  capture('xcrun', ['simctl', 'ui', udid, 'appearance', 'light']);
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
  spawnSync('xcrun', ['simctl', 'terminate', udid, bundleId], { stdio: 'ignore' });
  const name = `uitest-${stamp()}`;
  const bundle = join(dir, `${name}.xcresult`);
  const log = join(dir, `${name}.log`);
  const status = logged(log, 'xcodebuild', ['test-without-building', '-project', project, '-scheme', 'Enduragent', '-destination', `id=${udid}`, '-derivedDataPath', derivedData, '-parallel-testing-enabled', 'NO', '-resultBundlePath', bundle, ...proofs.map(proof => `-only-testing:EnduragentUITests/${proof}`)]);
  if (existsSync(bundle)) {
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
  console.log(`result bundle ${bundle}\nlog ${log}`);
  if (status !== 0) throw new Error(`test-without-building exited ${status}\n${tail(log)}`);
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
    if (sim.state !== 'Shutdown') capture('xcrun', ['simctl', 'shutdown', sim.udid]);
    capture('xcrun', ['simctl', 'delete', sim.udid]);
    console.log(`deleted ${simName(id)} ${sim.udid}`);
  } else {
    console.log(`no simulator ${simName(id)}; nothing to delete`);
  }
  if (findSim(id)) throw new Error(`${simName(id)} still exists after delete`);
  console.log(`evidence kept at ${dir}\n${readdirSync(dir).sort().join('\n')}`);
}

const commands = { doctor, build, create, install, launch, shot, test, parity, cleanup };
const [command, ...rest] = process.argv.slice(2);
if (!Object.hasOwn(commands, command ?? '')) {
  console.error(`Usage: sim.mjs <${Object.keys(commands).join('|')}> [arguments]`);
  process.exit(2);
}
try {
  commands[command](...rest);
} catch (error) {
  console.error(`sim.mjs ${command}: ${error.message}`);
  process.exitCode = 1;
}
