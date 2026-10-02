#!/usr/bin/env node
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';

const root = process.env.ENDURAGENT_VERIFY_FAKE_ROOT;
if (!root) throw new Error('fake tools require a test-owned root');
const command = basename(process.argv[1]);
const args = process.argv.slice(2);
const value = flag => args[args.indexOf(flag) + 1];
const devices = join(root, 'devices');
const deviceRecords = join(root, 'device-records');
mkdirSync(devices, { recursive: true });
mkdirSync(deviceRecords, { recursive: true });
writeFileSync(join(root, `call-${process.pid}.json`), JSON.stringify({ command, args }));

if (command === 'git') {
  process.stderr.write('not a git repository\n');
  process.exit(128);
}
if (command === 'date') process.stdout.write('2026-10-01-120000');
if (command === 'xcodebuild') {
  if (args.includes('-version')) {
    process.stdout.write('Xcode 26.6\n');
  } else if (args.includes('build-for-testing')) {
    const products = join(value('-derivedDataPath'), 'Build/Products');
    mkdirSync(join(products, 'Debug-iphonesimulator/Enduragent.app'), { recursive: true });
    writeFileSync(join(products, 'Debug-iphonesimulator/Enduragent.app/Info.plist'), 'fixture');
    writeFileSync(join(products, 'Enduragent.xctestrun'), 'fixture');
  } else {
    const bundle = value('-resultBundlePath');
    mkdirSync(bundle, { recursive: true });
    const classes = args.filter(arg => arg.startsWith('-only-testing:')).map(arg => arg.split('/')[1]);
    const testNodes = classes.filter(name => name !== process.env.VERIFY_MISSING_CLASS).map(name => ({
      name,
      nodeType: 'Test Suite',
      children: [{
        nodeType: 'Test Case',
        nodeIdentifier: `${name}/testVisibleResult()`,
        result: name === process.env.VERIFY_FAIL_CLASS ? 'Failed' : name === process.env.VERIFY_SKIP_CLASS ? 'Skipped' : 'Passed',
        durationInSeconds: 7,
      }],
    }));
    writeFileSync(join(bundle, 'tests.json'), JSON.stringify({ testNodes }));
    if (classes.includes(process.env.VERIFY_FAIL_CLASS)) process.exitCode = 65;
  }
}
if (command === 'plutil') process.stdout.write('icu.enduragent.app\n');
if (command === 'xcrun' && args[0] === 'xcresulttool') {
  if (args[1] === 'export') {
    writeFileSync(join(value('--output-path'), 'manifest.json'), '[]');
  } else {
    const tests = JSON.parse(readFileSync(join(value('--path'), 'tests.json'), 'utf8'));
    if (args[3] === 'tests') process.stdout.write(JSON.stringify(tests));
    else {
      const cases = tests.testNodes.flatMap(node => node.children);
      process.stdout.write(JSON.stringify({
        result: cases.some(node => node.result === 'Failed') ? 'Failed' : 'Passed',
        passedTests: cases.filter(node => node.result === 'Passed').length,
        failedTests: cases.filter(node => node.result === 'Failed').length,
        skippedTests: cases.filter(node => node.result === 'Skipped').length,
      }));
    }
  }
}
if (command === 'xcrun' && args[0] === 'simctl') {
  const action = args[1];
  if (action === 'list') {
    const listings = {
      devices: { devices: { fixture: readdirSync(devices).map(file => JSON.parse(readFileSync(join(deviceRecords, file), 'utf8'))) } },
      runtimes: { runtimes: [{ platform: 'iOS', isAvailable: true, version: '26.5', name: 'iOS 26.5', identifier: 'fixture-runtime' }] },
      devicetypes: { devicetypes: [{ name: 'iPhone 17e' }] },
    };
    process.stdout.write(JSON.stringify(listings[args[2]]));
  } else if (action === 'create') {
    const udid = `fixture-${process.pid}`;
    writeFileSync(join(deviceRecords, udid), JSON.stringify({ name: args[2], udid, state: 'Booted' }));
    writeFileSync(join(devices, udid), '');
    process.stdout.write(udid);
  } else if (action === 'delete') {
    rmSync(join(devices, args[2]));
  } else if (action === 'bootstatus' && process.env.VERIFY_FAIL_BOOT) {
    const device = JSON.parse(readFileSync(join(deviceRecords, args[2]), 'utf8'));
    if (device.name.endsWith('shard-2')) process.exitCode = 1;
  }
}
