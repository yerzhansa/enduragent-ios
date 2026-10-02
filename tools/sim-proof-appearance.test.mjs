import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { mock, test } from 'node:test';

test('proof commands select their appearance and restore light after a dark failure', async () => {
  const root = mkdtempSync(join(tmpdir(), 'enduragent-proof-appearance-'));
  mkdirSync(join(root, 'fixture'));
  writeFileSync(join(root, 'fixture', 'run.json'), '{}');
  const events = [];
  let appearance = 'dark';
  let failBuild = false;
  let selected = [];
  mock.module('node:child_process', {
    namedExports: {
      spawn() { throw new Error('appearance tests never spawn shards'); },
      execFileSync(command, args) {
        if (command === 'date') return '2026-10-01-120000';
        assert.equal(command, 'xcrun');
        if (args[0] === 'xcresulttool') {
          if (args[1] === 'export') {
            writeFileSync(join(args[args.indexOf('--output-path') + 1], 'manifest.json'), '[]');
            return '';
          }
          if (args[3] === 'tests') return JSON.stringify({ testNodes: selected.map(name => ({
            nodeType: 'Test Case', nodeIdentifier: `${name}/testAppearance()`, result: failBuild ? 'Failed' : 'Passed', durationInSeconds: 1,
          })) });
          return JSON.stringify({ result: failBuild ? 'Failed' : 'Passed', passedTests: failBuild ? 0 : selected.length, failedTests: failBuild ? selected.length : 0, skippedTests: 0 });
        }
        if (args.join(' ') === 'simctl list devices -j') {
          return JSON.stringify({ devices: { fixture: [{ name: 'enduragent-verify-fixture', udid: 'fixture-device' }] } });
        }
        assert.deepEqual(args.slice(0, 4), ['simctl', 'ui', 'fixture-device', 'appearance']);
        appearance = args[4];
        events.push(['appearance', appearance]);
        return '';
      },
      spawnSync(command, args) {
        if (command === 'xcrun') {
          assert.deepEqual(args, ['simctl', 'terminate', 'fixture-device', 'icu.enduragent.app']);
          return { status: 0 };
        }
        assert.equal(command, 'xcodebuild');
        selected = args.filter(arg => arg.startsWith('-only-testing:')).map(arg => arg.split('/')[1]);
        mkdirSync(args[args.indexOf('-resultBundlePath') + 1]);
        events.push(['proofs', appearance, ...args.filter(arg => arg.startsWith('-only-testing:'))]);
        return { status: failBuild ? 1 : 0 };
      },
    },
  });
  const originalArgs = process.argv;
  const originalRoot = process.env.ENDURAGENT_VERIFY_RUNS;
  process.env.ENDURAGENT_VERIFY_RUNS = root;
  try {
    for (const [index, proofs, failure] of [
      [0, ['ConfirmedPreviewProof'], false],
      [1, ['ConfirmedPreviewProof', 'ConfirmedPreviewDarkProof'], false],
      [2, ['ConfirmedPreviewDarkProof'], true],
    ]) {
      appearance = 'dark';
      events.length = 0;
      failBuild = failure;
      process.argv = ['node', 'sim.mjs', 'test', 'fixture', ...proofs];
      await import(`../.agents/skills/verify-ios/helpers/sim.mjs?appearance-test=${index}`);
      assert.equal(process.exitCode ?? 0, failure ? 1 : 0);
      process.exitCode = 0;
      assert.equal(appearance, 'light');
      assert.deepEqual(events.filter(event => event[0] === 'proofs'), proofs.map(proof => [
        'proofs', proof.endsWith('DarkProof') ? 'dark' : 'light', `-only-testing:EnduragentUITests/${proof}`,
      ]));
    }
  } finally {
    process.argv = originalArgs;
    if (originalRoot === undefined) delete process.env.ENDURAGENT_VERIFY_RUNS;
    else process.env.ENDURAGENT_VERIFY_RUNS = originalRoot;
    mock.restoreAll();
  }
});
