import { execFileSync } from 'node:child_process';
import { lstatSync, readFileSync, realpathSync } from 'node:fs';
import { basename, resolve, sep } from 'node:path';

const args = process.argv.slice(2);
if (args.length !== 0 && (args.length !== 2 || args[0] !== '--root')) {
  console.error('Usage: node tools/check-source.mjs [--root repository]');
  process.exit(2);
}
const root = realpathSync(resolve(args[1] ?? process.cwd()));
const forbiddenPath = /(?:^|\/)(?:docs|node_modules|\.build|build|dist|out|DerivedData|\.wrangler|\.swiftpm|xcuserdata|\.idea)(?:\/|$)|(?:^|\/)(?:\.env(?:\.[^/]*)?|\.dev\.vars(?:\.[^/]*)?|credentials(?:\.[^/]*)?|[^/]+\.(?:p12|p8|mobileprovision|keychain|keychain-db|ipa|xcarchive))$/i;
const language = /\b(?:CTL|ATL|TSB|TSS|IF|NP|Normalized\s+Power|[Nn]orm\s+[Pp]ower)\b/;
const fixture = /^apps\/ios\/.*\/Tests\/.*\/Fixtures\//;
let violations = 0;
let count = 0;
function report(file, rule) {
  violations++;
  console.error(`${JSON.stringify(file)} [${rule}]`);
}
function publicText(file, text) {
  if (file.endsWith('.md') && basename(file) !== 'NOTICE.md') {
    return [text.replace(/```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`]*`/g, '')];
  }
  if (/\.tsx?$/.test(file)) {
    return [...text.matchAll(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\/\/[^\n]*|\/\*[\s\S]*?\*\//g)].map(match => match[0]);
  }
  if (file.endsWith('.swift') && !file.includes('/Tests/')) {
    return [...text.matchAll(/\b(?:Text|Label|Button|Section|navigationTitle|alert|confirmationDialog|String\(localized:)\s*\(?(?:\s*)"((?:\\.|[^"\\])*)"/g)].map(match => match[1]);
  }
  return [];
}
try {
  const files = execFileSync('git', ['-C', root, 'ls-files', '-z'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 }).split('\0').filter(Boolean);
  for (const file of files) {
    count++;
    if (forbiddenPath.test(file)) {
      report(file, 'forbidden-path');
      continue;
    }
    const path = resolve(root, file);
    if (!path.startsWith(root + sep) || lstatSync(path).isSymbolicLink() || !realpathSync(path).startsWith(root + sep)) {
      report(file, 'unsafe-path');
      continue;
    }
    const bytes = readFileSync(path);
    if (bytes.includes(0)) {
      report(file, 'unexpected-binary');
      continue;
    }
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    if (/\bi\d{8,9}\b/.test(text)) report(file, 'intervals-id');
    if (/(?:["'](?:id|activity_?id)["']\s*:\s*["']?\d{9,}\b|\/activit(?:y|ies)\/\d{9,}\b|\bactivity_?[Ii][Dd]\s*[:=]\s*["']?\d{9,}\b)/.test(text)) report(file, 'activity-id');
    if (fixture.test(file) && [...text.matchAll(/\b(\d{4})-\d{2}-\d{2}\b/g)].some(match => Number(match[1]) >= 2015)) report(file, 'fixture-date');
    if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-or-v1-[a-f0-9]{32,}|AKIA[A-Z0-9]{16})\b/.test(text)) report(file, 'secret-shape');
    if (publicText(file, text).some(value => language.test(value))) report(file, 'public-language');
  }
  console.log(`check-source: ${count} tracked files; ${violations} violations.`);
  process.exitCode = violations ? 1 : 0;
} catch {
  console.error('check-source: inventory or file parsing failed; content omitted.');
  process.exitCode = 2;
}
