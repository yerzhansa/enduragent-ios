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
const appIcon = /^apps\/ios\/Enduragent\/Assets\.xcassets\/AppIcon\.appiconset\/AppIcon\.png$/;
const proofFile = /^apps\/ios\/EnduragentUITests\/[^/]+\.swift$/;
const featureFile = /^\.claude\/skills\/verify-ios\/features\/[^/]+\.md$/;
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
function isDebugOnly(text) {
  const lines = text.trim().split(/\r?\n/);
  if (lines[0].trim() !== '#if DEBUG') return false;
  let depth = 0;
  for (const [index, line] of lines.entries()) {
    if (/^\s*#if\b/.test(line)) {
      depth++;
    } else if (/^\s*#endif\b/.test(line)) {
      depth--;
      if (depth === 0 && index !== lines.length - 1) return false;
    } else if (depth === 1 && /^\s*#(?:else|elseif)\b/.test(line)) {
      return false;
    }
  }
  return depth === 0;
}
function hasExtraSecretStore(text) {
  return [...text.matchAll(/\b(?:class|struct|actor|enum|extension)\s+(\w+(?:\.\w+)*)([^{}]*)\{/g)]
    .some(([, name, declaration]) => {
      if (name === 'ICloudKeychainStore') return false;
      let header = declaration;
      while (/<[^<>]*>/.test(header)) header = header.replace(/<[^<>]*>/g, '');
      const inheritance = header.split(/\bwhere\b/)[0];
      return /^\s*:[^:]*\bSecretStore\b/.test(inheritance);
    });
}
function checkFeatureProofs(sources) {
  const classes = new Map();
  const mapped = new Set();
  const expectedSections = [
    'Sub-features',
    'How to get to it (user POV)',
    'Driving it with sim.mjs and XCUITest',
    'Gotchas',
  ];
  for (const [file, text] of sources) {
    if (!proofFile.test(file)) continue;
    const declarations = [...text.matchAll(/\bclass\s+(\w+)\s*:\s*XCTestCase\b/g)];
    for (const [index, declaration] of declarations.entries()) {
      const name = declaration[1];
      if (classes.has(name)) report(file, 'feature-proof-duplicate');
      const body = text.slice(declaration.index + declaration[0].length, declarations[index + 1]?.index ?? text.length);
      const methods = new Set([...body.matchAll(/\bfunc\s+(test\w+)\s*\(/g)].map(match => match[1]));
      classes.set(name, { file, methods });
    }
  }
  for (const [file, text] of sources) {
    if (!featureFile.test(file)) continue;
    const references = [...text.matchAll(/\b[A-Z][A-Za-z0-9]*(?:Proof|Probe)\b/g)].map(match => match[0]);
    if (references.some(name => !classes.has(name))) report(file, 'feature-proof-reference');
    if (basename(file) !== 'README.md') {
      for (const name of references) mapped.add(name);
      const sections = [...text.matchAll(/^## ([^\r\n]+)\r?$/gm)].map(match => match[1]);
      if (JSON.stringify(sections) !== JSON.stringify(expectedSections)) report(file, 'feature-proof-sections');
    }
    for (const [, name, method] of text.matchAll(/\b([A-Z][A-Za-z0-9]*(?:Proof|Probe))\/(test\w+)\b/g)) {
      if (!classes.get(name)?.methods.has(method)) report(file, 'feature-proof-method');
    }
  }
  for (const [name, { file }] of classes) {
    if (!mapped.has(name)) report(file, 'feature-proof-unmapped');
  }
}
try {
  const files = execFileSync('git', ['-C', root, 'ls-files', '-z'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 }).split('\0').filter(Boolean);
  const featureProofSources = new Map();
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
      if (!appIcon.test(file)) {
        report(file, 'unexpected-binary');
      }
      continue;
    }
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    if (file.endsWith('.swift') && hasExtraSecretStore(text)) report(file, 'single-secret-store');
    if (proofFile.test(file) || featureFile.test(file)) featureProofSources.set(file, text);
    if (/\bi\d{8,9}\b/.test(text)) report(file, 'intervals-id');
    if (file.endsWith('.swift') && /swiftlint:(?:disable|enable)/.test(text)) report(file, 'lint-disable');
    if (/^apps\/ios\/Packages\/EnduragentCoach\/Sources\/EnduragentCoach\/Records\/.*\.swift$/.test(file)
      && /\b(?:public|open)\b|@_spi\b/.test(text)) report(file, 'records-package-only');
    if (file === 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift') {
      const declaration = /^(.*?)\b(?:let|var|func)\s+(?:ledger|clock|process|records|work|interruption|live|finishedAway|waits|door|pass)\b/;
      const exposed = text.split('\n').some(line => {
        const member = declaration.exec(line.replace(/"(?:\\.|[^"\\])*"/g, '""'));
        return member && !/(?:^|\s)private(?:\s|$)/.test(member[1]);
      });
      if (exposed) report(file, 'mailbox-private-state');
    }
    if (/^apps\/ios\/Enduragent\/.*\.swift$/.test(file) && !file.endsWith('DebugView.swift') && /\bconfirmLine\s*=\s*#*"/.test(text)) report(file, 'uncatalogued-confirmation');
    if (/^apps\/ios\/Enduragent\/.*\.swift$/.test(file) && /\b(?:builder|environment)\s*\.\s*phrasebook\b/.test(text)) report(file, 'device-only-phrasebook');
    if (/^apps\/ios\/Enduragent\/.*\.swift$/.test(file) && /\b(?:errorLine|fixtureFeedback)\b/.test(text)
      && /\bimport\s+SwiftUI\b|\b(?:some\s+|:\s*)View\b/.test(text)
      && (!file.endsWith('DebugView.swift') || !isDebugOnly(text))) report(file, 'fixture-feedback-debug-only');
    if (/(?:["'](?:id|activity_?id)["']\s*:\s*["']?\d{9,}\b|\/activit(?:y|ies)\/\d{9,}\b|\bactivity_?[Ii][Dd]\s*[:=]\s*["']?\d{9,}\b)/.test(text)) report(file, 'activity-id');
    if (fixture.test(file) && [...text.matchAll(/\b(\d{4})-\d{2}-\d{2}\b/g)].some(match => Number(match[1]) >= 2015)) report(file, 'fixture-date');
    if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-or-v1-[a-f0-9]{32,}|AKIA[A-Z0-9]{16})\b/.test(text)) report(file, 'secret-shape');
    if (publicText(file, text).some(value => language.test(value))) report(file, 'public-language');
  }
  checkFeatureProofs(featureProofSources);
  console.log(`check-source: ${count} tracked files; ${violations} violations.`);
  process.exitCode = violations ? 1 : 0;
} catch {
  console.error('check-source: inventory or file parsing failed; content omitted.');
  process.exitCode = 2;
}
