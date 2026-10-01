import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const config = fileURLToPath(new URL('../.swiftlint.yml', import.meta.url));

test('starter_policy_in_package rejects direct grants in app code', () => {
  const root = mkdtempSync(join(tmpdir(), 'ios-starter-policy-check-'));
  try {
    for (const [path, rejected] of [
      ['apps/ios/Enduragent/App/Probe.swift', true],
      ['apps/ios/Enduragent/Credits/ProbeDebugView.swift', true],
      ['apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Probe.swift', false],
    ]) {
      const file = join(root, path);
      mkdirSync(dirname(file), { recursive: true });
      writeFileSync(file, [
        'let outcome = try await coach.credits.grant(deviceCheck: token)',
        'let outcome = try await credits . grant ( deviceCheck : token)',
        'let notice = await coach.claimStarter(deviceCheck: token)',
      ].join('\n') + '\n');
      const result = spawnSync('swiftlint', [
        'lint', '--config', config, '--quiet', '--no-cache', '--reporter', 'json', file,
      ], { encoding: 'utf8' });
      assert.ok(result.status === 0 || result.status === 2, result.stdout + result.stderr);
      const violations = JSON.parse(result.stdout).filter(row => row.rule_id === 'starter_policy_in_package');
      assert.deepEqual(violations.map(row => row.line).sort((a, b) => a - b), rejected ? [1, 2] : [], path);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('optional_try accepts only a standalone conditional container decode probe', () => {
  const root = mkdtempSync(join(tmpdir(), 'ios-swiftlint-check-'));
  try {
    const file = join(root, 'Sources/EnduragentCoach/Testing/Probe.swift');
    mkdirSync(dirname(file), { recursive: true });
    const cases = [
      ['let value = try? load()', true],
      ['let value = (try? load()) ?? []', true],
      ['let value = (try? container.decode(Int.self)) ?? 0', true],
      ['if let value = try? container.decode(Int.self) ?? 0 {', true],
      ['if let value = try? container.decode(Int.self) { let other = try? load() }', true],
      ['if let value = try? container.decode(Bool.self) {', false],
      ['if let value = try? container.decode([JSONValuePayload].self) {', false],
      ['if let value = try? container.decode([String: JSONValuePayload].self) {', false],
    ];
    writeFileSync(file, cases.map(([source]) => source).join('\n') + '\n');
    const result = spawnSync('swiftlint', [
      'lint', '--config', config, '--quiet', '--no-cache', '--reporter', 'json', file,
    ], { encoding: 'utf8' });
    assert.equal(result.status, 2, result.stdout + result.stderr);
    const optional = JSON.parse(result.stdout).filter(row => row.rule_id === 'optional_try');
    assert.deepEqual(optional.map(row => row.line).sort((a, b) => a - b),
      cases.flatMap(([, rejected], index) => rejected ? [index + 1] : []));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('one_session_factory rejects every construction outside the package factory', () => {
  const root = mkdtempSync(join(tmpdir(), 'ios-session-factory-check-'));
  const probes = [
    'let session = URLSession(configuration: config)',
    'let session = URLSession.init(configuration: config)',
    'let session: URLSession = .init(configuration: config)',
    'let session = URLSession.shared',
    'let session = URLSession . shared',
    'let client = Client(session: .shared)',
    'let configuration = URLSessionConfiguration.ephemeral',
    'let app = UIApplication.shared',
    'let scheduler = BGTaskScheduler.shared',
  ];
  try {
    for (const [path, rejected] of [
      ['apps/ios/Enduragent/App/Probe.swift', true],
      ['apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Probe.swift', true],
      ['apps/ios/Enduragent/App/Transport/HTTPSession.swift', true],
      ['apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Probe.swift', false],
      ['apps/ios/EnduragentTests/Probe.swift', false],
      ['apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Transport/HTTPSession.swift', false],
    ]) {
      const file = join(root, path);
      mkdirSync(dirname(file), { recursive: true });
      writeFileSync(file, probes.join('\n') + '\n');
      const result = spawnSync('swiftlint', [
        'lint', '--config', config, '--quiet', '--no-cache', '--reporter', 'json', file,
      ], { encoding: 'utf8' });
      assert.ok(result.status === 0 || result.status === 2, result.stdout + result.stderr);
      const violations = JSON.parse(result.stdout).filter(row => row.rule_id === 'one_session_factory');
      assert.deepEqual(violations.map(row => row.line).sort((a, b) => a - b),
        rejected ? [1, 2, 3, 4, 5, 6, 7] : [], path);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
