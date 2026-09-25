import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const checker = fileURLToPath(new URL('./check-lint-baseline.mjs', import.meta.url));
const entry = (file, rule, text) => ({ text, violation: { ruleIdentifier: rule, location: { file, line: 1, character: 1 } } });
const unwrap = entry('apps/ios/A.swift', 'force_unwrapping', 'let a = b!');
const optionalTry = entry('apps/ios/B.swift', 'optional_try', 'let c = try? d()');

function run(base, head) {
  const root = mkdtempSync(join(tmpdir(), 'lint-baseline-check-'));
  const git = (...args) => execFileSync('git', ['-C', root, ...args], { stdio: 'ignore' });
  try {
    git('init', '-q', '-b', 'main');
    git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'root');
    if (base) {
      writeFileSync(join(root, '.swiftlint-baseline.json'), JSON.stringify(base));
      git('add', '.');
      git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'base');
    }
    writeFileSync(join(root, '.swiftlint-baseline.json'), JSON.stringify(head));
    const result = spawnSync(process.execPath, [checker, '--root', root], { encoding: 'utf8', env: { ...process.env, LINT_BASELINE_BASE: 'main' } });
    return { status: result.status, output: result.stdout + result.stderr };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test('accepts a baseline that shrinks', () => {
  const result = run([unwrap, optionalTry], [unwrap]);
  assert.equal(result.status, 0, result.output);
});

test('accepts a rewritten line of the same rule', () => {
  const result = run([unwrap], [entry('apps/ios/A.swift', 'force_unwrapping', 'let a =\n b!')]);
  assert.equal(result.status, 0, result.output);
});

test('accepts an unchanged baseline', () => {
  const result = run([unwrap], [unwrap]);
  assert.equal(result.status, 0, result.output);
});

test('rejects a new entry', () => {
  const result = run([unwrap], [unwrap, optionalTry]);
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /optional_try/);
});

test('rejects a second copy of an existing entry', () => {
  const result = run([unwrap], [unwrap, unwrap]);
  assert.equal(result.status, 1, result.output);
});

test('rejects an entry moved to another file', () => {
  const result = run([unwrap], [entry('apps/ios/C.swift', 'force_unwrapping', 'let a = b!')]);
  assert.equal(result.status, 1, result.output);
});

test('accepts the commit that introduces the baseline', () => {
  const result = run(undefined, [unwrap]);
  assert.equal(result.status, 0, result.output);
});
