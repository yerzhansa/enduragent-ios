import { readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

export function parseOptions(argv, env, repo) {
  const values = { '--build-folder': env.ENDURAGENT_VERIFY_BUILD ?? join(repo, 'DerivedData'), '--shards': '1', '--timings': undefined };
  const args = [];
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index];
    if (!Object.hasOwn(values, argument)) {
      args.push(argument);
      continue;
    }
    const value = argv[++index];
    if (!value || value.startsWith('-')) throw new Error(`${argument} needs a value`);
    values[argument] = value;
  }
  const shards = Number(values['--shards']);
  if (!Number.isSafeInteger(shards) || shards < 1) throw new Error('--shards must be a positive whole number');
  return {
    command: args.shift(), args,
    buildFolder: resolve(values['--build-folder']), shards,
    timings: values['--timings'] ? resolve(values['--timings']) : undefined,
  };
}

export function proofClasses(repo) {
  const folder = join(repo, 'apps/ios/EnduragentUITests');
  return readdirSync(folder).filter(file => file.endsWith('.swift')).flatMap(file =>
    [...readFileSync(join(folder, file), 'utf8').matchAll(/\bfinal\s+class\s+(\w+Proof)\s*:\s*XCTestCase\b/g)].map(match => match[1])
  ).sort();
}

export function planShards(proofs, count, timings = {}) {
  if (!Number.isSafeInteger(count) || count < 1) throw new Error('shards must be a positive whole number');
  if (proofs.length < count) throw new Error('need at least as many classes as shards');
  if (new Set(proofs).size !== proofs.length) throw new Error('duplicate proof class');
  if (proofs.some(name => !/^[A-Za-z_]\w*$/.test(name))) throw new Error('suite takes class names, not test methods');
  if (!timings || typeof timings !== 'object' || Array.isArray(timings)) throw new Error('timings must map class names to seconds');
  const durations = Object.values(timings);
  if (durations.some(seconds => !Number.isFinite(seconds) || seconds <= 0)) throw new Error('duration must be a positive number of seconds');
  const fallback = durations.length ? durations.reduce((sum, seconds) => sum + seconds, 0) / durations.length : 1;
  const ordered = proofs.map(name => ({ name, seconds: timings[name] ?? fallback }));
  if (durations.length) ordered.sort((a, b) => b.seconds - a.seconds || a.name.localeCompare(b.name));
  const shards = Array.from({ length: count }, () => ({ proofs: [], estimatedSeconds: 0 }));
  for (const proof of ordered) {
    const shard = shards.reduce((best, candidate) => candidate.estimatedSeconds < best.estimatedSeconds ? candidate : best);
    shard.proofs.push(proof.name);
    shard.estimatedSeconds += proof.seconds;
  }
  return shards;
}

export function summarizeTests(tree, proofs) {
  if (!Array.isArray(tree.testNodes)) throw new Error('test result has no testNodes');
  const rows = proofs.map(name => ({ name, passed: 0, failed: 0, skipped: 0, missing: 0, seconds: 0 }));
  function walk(node) {
    if (node.nodeType === 'Test Case') {
      const name = node.nodeIdentifier?.split('/')[0];
      const row = rows.find(item => item.name === name);
      if (!row) throw new Error(`unexpected test result ${node.nodeIdentifier}`);
      const field = { Passed: 'passed', Failed: 'failed', Skipped: 'skipped' }[node.result];
      if (!field) throw new Error(`unverified test result ${node.result}`);
      row[field]++;
      if (!Number.isFinite(node.durationInSeconds) || node.durationInSeconds < 0) throw new Error(`missing duration for ${node.nodeIdentifier}`);
      row.seconds += node.durationInSeconds;
    } else {
      for (const child of node.children ?? []) walk(child);
    }
  }
  for (const node of tree.testNodes) walk(node);
  for (const row of rows) row.missing = row.passed + row.failed + row.skipped === 0 ? 1 : 0;
  return rows;
}
