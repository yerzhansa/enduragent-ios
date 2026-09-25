import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const args = process.argv.slice(2);
if (args.length > 2 || (args.length > 0 && args[0] !== '--root')) {
  console.error('Usage: node tools/check-lint-baseline.mjs [--root repository]');
  process.exit(2);
}
const root = resolve(args[1] ?? process.cwd());
const base = process.env.LINT_BASELINE_BASE ?? 'origin/main';
const file = '.swiftlint-baseline.json';

function key(entry) {
  const { ruleIdentifier, location } = entry.violation;
  return JSON.stringify([location.file, ruleIdentifier]);
}
function tally(entries) {
  const counts = new Map();
  for (const entry of entries) counts.set(key(entry), (counts.get(key(entry)) ?? 0) + 1);
  return counts;
}

const current = tally(JSON.parse(readFileSync(resolve(root, file), 'utf8')));
let previous;
try {
  previous = tally(JSON.parse(execFileSync('git', ['-C', root, 'show', `${base}:${file}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 16 * 1024 * 1024 })));
} catch {
  console.log(`check-lint-baseline: ${base} has no ${file}; nothing to compare.`);
  process.exit(0);
}

let added = 0;
for (const [entry, count] of current) {
  const extra = count - (previous.get(entry) ?? 0);
  if (extra > 0) {
    added += extra;
    const [path, rule] = JSON.parse(entry);
    console.error(`${JSON.stringify(path)} [${rule}] added to the baseline`);
  }
}
const size = [...current.values()].reduce((sum, count) => sum + count, 0);
const before = [...previous.values()].reduce((sum, count) => sum + count, 0);
console.log(`check-lint-baseline: ${before} entries on ${base}, ${size} now, ${added} added.`);
if (added) console.error('Fix the violation instead of adding it to the baseline.');
process.exitCode = added ? 1 : 0;
