import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const config = fileURLToPath(new URL('../.swiftlint.yml', import.meta.url));

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
