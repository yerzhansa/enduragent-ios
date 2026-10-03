import { execFileSync } from 'node:child_process';
import { lstatSync, readFileSync, readlinkSync, realpathSync } from 'node:fs';
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path';

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
const upgradeStore = /^apps\/ios\/Packages\/EnduragentCoach\/Tests\/EnduragentCoachTests\/Fixtures\/(?:v1-upgrade\/(?:history|review)|pre-vault-5de5c782|build-2bbe2ee)\/(?:synced|local)-records\.store$/;
const proofFile = /^apps\/ios\/EnduragentUITests\/[^/]+\.swift$/;
const featureFile = /^\.agents\/skills\/verify-ios\/features\/[^/]+\.md$/;
let violations = 0;
let count = 0;
function report(file, rule) {
  violations++;
  console.error(`${JSON.stringify(file)} [${rule}]`);
}
function readPlist(path) {
  return JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', '--', path], { encoding: 'utf8' }));
}
function checkXcodeBuildSettings(file, path) {
  const { rootObject, objects } = readPlist(path);
  const project = objects[rootObject];
  const configurations = owner => objects[owner.buildConfigurationList].buildConfigurations.map(id => objects[id]);
  const shared = new Map(configurations(project).map(config => [config.name, config.buildSettings]));
  for (const id of project.targets) {
    const target = objects[id];
    for (const config of configurations(target)) {
      const settings = { ...shared.get(config.name), ...config.buildSettings };
      if (!settings.DEVELOPMENT_TEAM || settings.CODE_SIGN_STYLE !== 'Automatic' || settings.SWIFT_VERSION !== '6.0') {
        report(file, 'xcode-shared-build-settings');
      }
      if (target.productType !== 'com.apple.product-type.application' || config.name !== 'DebugKeychainProof') continue;
      const entitlementPath = settings.CODE_SIGN_ENTITLEMENTS;
      if (!entitlementPath) {
        report(file, 'keychain-proof-storage-isolation');
        continue;
      }
      const entitlements = readPlist(resolve(dirname(path), '..', entitlementPath));
      const groups = entitlements['keychain-access-groups'];
      if (settings.PRODUCT_BUNDLE_IDENTIFIER !== 'icu.enduragent.keychainproof'
        || !Array.isArray(groups) || groups.length !== 1
        || groups[0] !== '$(AppIdentifierPrefix)icu.enduragent.keychainproof'
        || Object.keys(entitlements).some(key => /^com\.apple\.developer\.(?:icloud|ubiquity)-/.test(key))) {
        report(file, 'keychain-proof-storage-isolation');
      }
    }
  }
}
function isSafeTrackedLink(path, trackedFiles) {
  let resolved;
  try {
    resolved = realpathSync.native(path);
  } catch (error) {
    if (['ENOENT', 'ENOTDIR', 'ELOOP'].includes(error.code)) return false;
    throw error;
  }
  if (resolved !== root && !resolved.startsWith(root + sep)) return false;
  if (!trackedFiles.has(resolved) && ![...trackedFiles].some(file => file.startsWith(resolved + sep))) return false;
  const pending = relative(root, path).split(sep);
  let current = root;
  while (pending.length) {
    const next = resolve(current, pending.shift());
    if (next !== root && !next.startsWith(root + sep)) return false;
    if (lstatSync(next).isSymbolicLink()) {
      if (!trackedFiles.has(next)) return false;
      const target = readlinkSync(next);
      if (isAbsolute(target)) return false;
      pending.unshift(...target.split(sep));
    } else {
      current = next;
    }
  }
  return true;
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
function hasReleaseReference(text, reference) {
  const guards = [];
  for (const line of text.split(/\r?\n/)) {
    if (/^\s*#if\b/.test(line)) {
      guards.push({ debug: /^\s*#if\s+DEBUG\s*$/.test(line), alternate: false });
    } else if (/^\s*#(?:else|elseif)\b/.test(line)) {
      if (guards.length) guards.at(-1).alternate = true;
    } else if (/^\s*#endif\b/.test(line)) {
      guards.pop();
    } else if (reference.test(line) && !guards.some(guard => guard.debug && !guard.alternate)) {
      return true;
    }
  }
  return false;
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
function hasExposedMailboxState(text) {
  const code = text.replace(/(#+)?("""[\s\S]*?"""|"(?:\\.|[^"\\])*")\1/g, '""');
  let depth = 0;
  let projection = false;
  for (const match of code.matchAll(/([^{};\n]*)([{};\n]|$)/g)) {
    const [, declaration, boundary] = match;
    const opensBody = boundary === '{' || (boundary === '\n' && /^\s*\{/.test(code.slice(match.index + match[0].length)));
    if (depth === 1) {
      const member = /^(.*?)\b(let|var)\s+/.exec(declaration);
      if (member && !/(?:^|\s)private(?:\s|$)/.test(member[1])
        && !/^\s*package\s+let\s+chatId\s*:\s*ChatID\s*$/.test(declaration)) {
        if (member[2] === 'let' || /\blazy\b/.test(member[1]) || declaration.includes('=') || !opensBody) return true;
        projection = true;
      }
    }
    if (depth === 2 && projection && opensBody
      && /^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:nonmutating|mutating)\s+)?(?:set|_modify|willSet|didSet)(?:\s*\([^)]*\))?\s*$/.test(declaration)) return true;
    if (boundary === '{') depth++;
    if (boundary === '}') depth--;
    if (depth === 1 && boundary === '}') projection = false;
  }
  return false;
}
function trailingBlocks(code, pattern) {
  return [...code.matchAll(pattern)].flatMap(match => {
    let parentheses = 0;
    let depth = 0;
    let start;
    for (let index = match.index + match[0].length; index < code.length; index++) {
      const token = code[index];
      if (start === undefined) {
        if (token === '(') parentheses++;
        if (token === ')') parentheses--;
        if (token !== '{' || parentheses !== 0) continue;
        start = index;
      }
      if (token === '{') depth++;
      if (token === '}' && --depth === 0) return [[start, index]];
    }
    return [];
  });
}
function hasUnboundedTestWait(text) {
  const code = text.replace(/(#+)?("""[\s\S]*?"""|"(?:\\.|[^"\\])*")\1/g, '""');
  const loops = trailingBlocks(code, /\bwhile\b/g);
  const deadlines = trailingBlocks(code, /\bbeforeDeadline\b/g);
  return [...code.matchAll(/\bawait\s+(?:[\w.]+\s*\.\s*waitUnlessCancelled\s*\(|withCheckedContinuation\b)/g)]
    .some(wait => loops.some(([start, end]) => start < wait.index && wait.index < end)
      && !deadlines.some(([start, end]) => start < wait.index && wait.index < end));
}
function checkNavigationStacks(sources) {
  const views = new Map();
  const roots = [];
  const declarations = /\bstruct\s+(\w+)\s*:\s*View\b/g;
  for (const [file, text] of sources) {
    const code = text.replace(/(#+)?("""[\s\S]*?"""|"(?:\\.|[^"\\])*")\1/g, '""');
    const names = [...code.matchAll(declarations)].map(match => match[1]);
    for (const [index, [start, end]] of trailingBlocks(code, declarations).entries()) {
      const body = code.slice(start + 1, end);
      views.set(names[index], { file, body });
      for (const [stackStart, stackEnd] of trailingBlocks(body, /\bNavigationStack\s*(?=\(\s*path\s*:)/g)) {
        roots.push({ file, body: body.slice(stackStart + 1, stackEnd) });
      }
    }
  }
  const visited = new Set();
  const reported = new Set();
  while (roots.length) {
    const { file, body } = roots.pop();
    let content = body;
    for (const [start, end] of trailingBlocks(body, /\.(?:sheet|fullScreenCover)\b/g)) {
      content = content.slice(0, start) + ' '.repeat(end - start + 1) + content.slice(end + 1);
    }
    if (/\bNavigationStack\b/.test(content) && !reported.has(file)) {
      report(file, 'shell-navigation-stack-owner');
      reported.add(file);
    }
    for (const [, name] of content.matchAll(/\b(\w+)\s*\(/g)) {
      if (views.has(name) && !visited.has(name)) {
        visited.add(name);
        roots.push(views.get(name));
      }
    }
  }
}
function hasLiteralTestHangGuard(text) {
  const code = text.replace(/(#+)?("""[\s\S]*?"""|"(?:\\.|[^"\\])*")\1/g, '""');
  const duration = String.raw`(?:Duration\s*\.\s*)?\.?(?:seconds|milliseconds|microseconds|nanoseconds|zero)\b`;
  return new RegExp(String.raw`\bwithin(?:\s+\w+\s*:\s*\w+\s*=|\s*:)\s*${duration}`).test(code)
    || new RegExp(String.raw`\bContinuousClock(?:\s*\(\s*\))?\s*\.\s*now\s*\+\s*${duration}`).test(code)
    || new RegExp(String.raw`\baddTask\s*\{\s*try\s+await\s+Task\s*\.\s*sleep\s*\(\s*for\s*:\s*${duration}(?:\s*\([^)]*\))?\s*\)\s*;?\s*return\s+(?:false|nil)\b`).test(code);
}
function checkLedgerIndexVersion(file, text) {
  const versions = new Map([
    ['ledger-indexes-v1', ['deviceId,hlcWallMs,hlcLogical', 'kind,chatId']],
  ]);
  const modifier = /@Attribute\(\s*hashModifier:\s*"(ledger-indexes-v\d+)"\s*\)\s*var\s+deviceId\b/.exec(text)?.[1];
  const declarations = [...text.matchAll(/#Index\s*<\s*StoredAthleteRecord\s*>\s*\(([^)]*)\)/g)];
  const indexes = declarations.flatMap(match => [...match[1].matchAll(/\[([^\]]*)\]/g)]
    .map(fields => fields[1].replace(/\s|\\\./g, ''))).sort();
  const expected = versions.get(modifier);
  if (!expected || JSON.stringify(indexes) !== JSON.stringify([...expected].sort())) {
    report(file, 'ledger-index-version');
  }
}
function checkFeatureProofs(sources) {
  const classes = new Map();
  const mapped = new Set();
  for (const [file, text] of sources) {
    if (!proofFile.test(file)) continue;
    const declarations = [...text.matchAll(/\bclass\s+(\w+)\s*:\s*XCTestCase\b/g)];
    for (const [index, declaration] of declarations.entries()) {
      const name = declaration[1];
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
  const trackedFiles = new Set(files.map(file => resolve(root, file)));
  const featureProofSources = new Map();
  const appNavigationSources = new Map();
  for (const file of files) {
    count++;
    if (forbiddenPath.test(file)) {
      report(file, 'forbidden-path');
      continue;
    }
    const path = resolve(root, file);
    if (!path.startsWith(root + sep)) {
      report(file, 'unsafe-path');
      continue;
    }
    if (lstatSync(path).isSymbolicLink()) {
      if (!isSafeTrackedLink(path, trackedFiles)) report(file, 'unsafe-path');
      continue;
    }
    if (!realpathSync(path).startsWith(root + sep)) {
      report(file, 'unsafe-path');
      continue;
    }
    const bytes = readFileSync(path);
    if (bytes.includes(0)) {
      if (!appIcon.test(file) && !(upgradeStore.test(file) && bytes.subarray(0, 16).equals(Buffer.from('SQLite format 3\0')))) {
        report(file, 'unexpected-binary');
      }
      continue;
    }
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    if (file === 'apps/ios/Enduragent.xcodeproj/project.pbxproj') checkXcodeBuildSettings(file, path);
    if (/^apps\/ios\/Enduragent\/.*\.swift$/.test(file)) appNavigationSources.set(file, text);
    if ((/^apps\/ios\/(?:Packages\/[^/]+\/Tests\/|Enduragent(?:UI|Phone)?Tests\/).*\.swift$/.test(file)
        && /\b(?:temporaryDirectory|NSTemporaryDirectory)\b|\/tmp\//.test(text))
      || (/^apps\/ios\/EnduragentTests\/.*\.swift$/.test(file)
        && (/\bremoveItem\s*\(/.test(text)
          || (file !== 'apps/ios/EnduragentTests/FixtureTestScope.swift'
            && /\bAppServices\s*\.\s*fixture\s*\(/.test(text))))) report(file, 'app-fixture-folder-ownership');
    if (/^apps\/ios\/Enduragent\/.*\.swift$/.test(file)
      && hasReleaseReference(text, /\b(?:FixtureLaunch|EnduragentCoachFixtures)\b/)) report(file, 'fixture-launch-debug-only');
    if (proofFile.test(file) && basename(file) !== 'TutorialHarness.swift'
      && (/\.launchArguments\s*(?:=|\+=)|\.waitFor(?:Non)?Existence\s*\(|\bXCTWaiter\.wait\s*\(|\btimeout\s*:/.test(text))) report(file, 'ui-proof-shared-helpers');
    if (proofFile.test(file)
      && /\bnamed\s*\(\s*\w+\s*,\s*"(?:fixture\.(?:expire|historyHead|requestCount|modelRequestCount)|debug\.(?:records|leases))"/.test(text)) report(file, 'ui-proof-debug-scrolling');
    if (proofFile.test(file) && /\bXCTSkip(?:If|Unless)?\b/.test(text)) report(file, 'ui-proof-no-skips');
    if (file.endsWith('.swift') && hasExtraSecretStore(text)) report(file, 'single-secret-store');
    if (/^apps\/ios\/(?:Packages\/EnduragentCoach\/Tests\/|EnduragentTests\/).*\.swift$/.test(file)
      && hasUnboundedTestWait(text)) report(file, 'test-wait-deadline');
    if (/^apps\/ios\/(?:Packages\/EnduragentCoach\/(?:Tests\/|Sources\/EnduragentCoachFixtures\/)|EnduragentTests\/).*\.swift$/.test(file)
      && hasLiteralTestHangGuard(text)) report(file, 'test-hang-guard-duration');
    if (proofFile.test(file) || featureFile.test(file)) featureProofSources.set(file, text);
    if (/\bi\d{8,9}\b/.test(text)) report(file, 'intervals-id');
    if (/^apps\/ios\/Enduragent\/.*\.swift$/.test(file) && /\bInt\s*\((?!\s*exactly:)\s*(?:[^;\n]*\.rounded\s*\(|(?:floor|ceil)\s*\()/.test(text)) report(file, 'app-number-formatting');
    if (file.endsWith('.swift') && /swiftlint:(?:disable|enable)/.test(text)) report(file, 'lint-disable');
    if (/^apps\/ios\/Packages\/EnduragentCoach\/Sources\/EnduragentCoach\/Records\/.*\.swift$/.test(file)
      && /\b(?:public|open)\b|@_spi\b/.test(text)) report(file, 'records-package-only');
    if (file === 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Records/StoredAthleteRecord.swift') {
      checkLedgerIndexVersion(file, text);
    }
    if (file === 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift') {
      if (hasExposedMailboxState(text)) report(file, 'mailbox-private-state');
    }
    if (/(?:["'](?:id|activity_?id)["']\s*:\s*["']?\d{9,}\b|\/activit(?:y|ies)\/\d{9,}\b|\bactivity_?[Ii][Dd]\s*[:=]\s*["']?\d{9,}\b)/.test(text)) report(file, 'activity-id');
    if (fixture.test(file) && [...text.matchAll(/\b(\d{4})-\d{2}-\d{2}\b/g)].some(match => Number(match[1]) >= 2015)) report(file, 'fixture-date');
    if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-or-v1-[a-f0-9]{32,}|AKIA[A-Z0-9]{16})\b/.test(text)) report(file, 'secret-shape');
    if (publicText(file, text).some(value => language.test(value))) report(file, 'public-language');
  }
  checkFeatureProofs(featureProofSources);
  checkNavigationStacks(appNavigationSources);
  console.log(`check-source: ${count} tracked files; ${violations} violations.`);
  process.exitCode = violations ? 1 : 0;
} catch {
  console.error('check-source: inventory or file parsing failed; content omitted.');
  process.exitCode = 2;
}
