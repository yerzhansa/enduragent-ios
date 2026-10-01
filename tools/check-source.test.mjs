import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const checker = fileURLToPath(new URL('./check-source.mjs', import.meta.url));
function run(files, tracked = true) {
  const root = mkdtempSync(join(tmpdir(), 'ios-source-check-'));
  try {
    execFileSync('git', ['init', '-q', root]);
    for (const [file, content] of Object.entries(files)) {
      mkdirSync(dirname(join(root, file)), { recursive: true });
      writeFileSync(join(root, file), content);
    }
    if (tracked) execFileSync('git', ['-C', root, 'add', '-f', '.']);
    const result = spawnSync(process.execPath, [checker, '--root', root], { encoding: 'utf8' });
    return { status: result.status, output: result.stdout + result.stderr };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const fixture = 'apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures/intervals-activity.json';
const sensitiveID = 'i' + '8'.repeat(8);
const activityID = '9'.repeat(11);
const recordModel = 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Records/StoredAthleteRecord.swift';
const ledgerIndexes = String.raw`#Index<StoredAthleteRecord>([\.deviceId, \.hlcWallMs, \.hlcLogical], [\.kind, \.chatId])`;
const ledgerIndexVersion = '@Attribute(hashModifier: "ledger-indexes-v1")';

for (const indexes of [
  String.raw`#Index<StoredAthleteRecord>([\.deviceId, \.hlcWallMs, \.hlcLogical])`,
  String.raw`#Index<StoredAthleteRecord>([\.deviceId, \.hlcLogical, \.hlcWallMs], [\.kind, \.chatId])`,
  String.raw`#Index<StoredAthleteRecord>([\.deviceId, \.hlcWallMs, \.hlcLogical], [\.kind, \.chatId], [\.ulid])`,
  '',
]) {
  test(`rejects changed ledger indexes with an unchanged model version: ${indexes}`, () => {
    const result = run({ [recordModel]: `${indexes}\n${ledgerIndexVersion}\nvar deviceId: String = ""` });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /ledger-index-version/);
  });
}

test('accepts the registered ledger index set and version', () => {
  const result = run({ [recordModel]: `${ledgerIndexes}\n${ledgerIndexVersion}\nvar deviceId: String = ""` });
  assert.equal(result.status, 0, result.output);
});

test('rejects unregistered ledger index versions', () => {
  const result = run({ [recordModel]: `${ledgerIndexes}\n@Attribute(hashModifier: "ledger-indexes-v2")\nvar deviceId: String = ""` });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /ledger-index-version/);
});

test('rejects ledger indexes without a model version modifier', () => {
  const result = run({ [recordModel]: `${ledgerIndexes}\nvar deviceId: String = ""` });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /ledger-index-version/);
});

for (const [name, file, value, code] of [
  ['rounded app number', 'apps/ios/Enduragent/Onboarding/ConnectView.swift', 'String(Int(value.rounded()))', 'app-number-formatting'],
  ['intervals identifier', 'apps/ios/value.swift', sensitiveID, 'intervals-id'],
  ['large JSON activity identifier', fixture, JSON.stringify({ id: activityID }), 'activity-id'],
  ['large activity URL', 'README.md', '/activity/' + activityID, 'activity-id'],
  ['current-era fixture date', fixture, '{"start_date_local":"2026-06-07"}', 'fixture-date'],
  ['environment file', '.env.production', 'TOKEN=placeholder', 'forbidden-path'],
  ['local app credentials', 'apps/ios/.dev.vars', 'TOKEN=placeholder', 'forbidden-path'],
  ['build output', 'apps/ios/.build/debug/app', 'binary', 'forbidden-path'],
  ['ignored documentation', 'docs/example.md', 'text', 'forbidden-path'],
  ['private key', 'key.txt', '-----BEGIN ' + 'PRIVATE KEY-----', 'secret-shape'],
  ['app TypeScript public wording', 'packages/i18n/scripts/message.ts', 'const message = "Your CTL is rising";', 'public-language'],
  ['Swift label', 'apps/ios/Enduragent/Screen.swift', 'Text("Normalized Power")', 'public-language'],
  ['public prose', 'README.md', 'Your CTL is rising.', 'public-language'],
  ['SwiftLint disable command', 'apps/ios/Enduragent/Screen.swift', '// swiftlint:disable:this no_comments', 'lint-disable'],
]) {
  test(`rejects ${name} without printing matched data`, () => {
    const result = run({ [file]: value });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, new RegExp(code));
    assert.ok(!result.output.includes(sensitiveID));
    assert.ok(!result.output.includes(activityID));
  });
}

test('accepts the App Store 1024 icon', () => {
  const result = run({
    'apps/ios/Enduragent/Assets.xcassets/AppIcon.appiconset/AppIcon.png': Buffer.from([137, 80, 78, 71, 0, 1, 2, 3]),
  });
  assert.equal(result.status, 0, result.output);
});

test('accepts historical fixtures and technical identifiers', () => {
  const result = run({
    [fixture]: '{"id":"i1234567","start_date_local":"1998-06-07","icu_training_load":120}',
    'apps/ios/Screen.swift': 'let CTL = 1\nlet codingKey = "NP"\nText("Fitness")',
    'NOTICE.md': 'THE SOFTWARE IS PROVIDED AS IS, IF ANY.',
    'packages/i18n/catalogs/en.json': '{"NP":"weighted average power","IF":"Intensity"}',
    'packages/i18n/catalogs/sv.json': '{"legacy":"TSB"}',
    'apps/ios/Resources/Phrasebook.json': '{"legacy":"TSB"}',
    'README.md': 'Fitness and Load.\n```\nCTL\n```\nUse `NP` as the API field.',
  });
  assert.equal(result.status, 0, result.output);
});

test('does not inspect untracked credentials', () => {
  const result = run({ '.dev.vars': 'secret' }, false);
  assert.equal(result.status, 0, result.output);
});

const mailbox = 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift';
for (const declaration of [
  'var runner: TurnRunner',
  'let renamed: Ledger',
  'private(set) var runner: TurnRunner',
  'fileprivate let runner: TurnRunner',
  'public nonisolated let renamed: Clock',
  'package(set) var state: State',
  '@ObservationIgnored public private(set) lazy var state = State()',
  'package var chatId: ChatID',
  'package let (a, b) = (1, 2)',
  'var `default`: TurnRunner',
  'lazy var state = State()',
  'lazy var state: State = { State() }()',
  'var state = makeState { State() }',
  'var state: State { willSet { record(newValue) } }',
  'var state: State { didSet { record(oldValue) } }',
  'var state = State() { didSet { record(oldValue) } }',
  'var exposed: State { get { state } set { state = newValue } }',
  'private(set) var exposed: State { get { state } set(value) { state = value } }',
  'var exposed: State { _read { yield state } _modify { yield &state } }',
  'var exposed: State { get { state } nonmutating set { replace(newValue) } }',
  'var exposed: State { get { state } @_transparent set { state = newValue } }',
  'var exposed: State { _read { yield state } @_transparent _modify { yield &state } }',
  'var exposed: State\n{\nget { state }\nset\n{ state = newValue }\n}',
]) {
  test(`rejects exposed mailbox state: ${declaration}`, () => {
    const result = run({ [mailbox]: `package actor ChatMailbox {\n${declaration}\n}` });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /\[mailbox-private-state\]/);
  });
}

for (const [name, source] of [
  ['same-line member', 'package actor ChatMailbox { var runner: TurnRunner }'],
  ['member after a method', 'package actor ChatMailbox { func accept() {} ; var runner: TurnRunner }'],
  ['member after private state', 'package actor ChatMailbox { private let hidden = 1; var runner: TurnRunner }'],
  ['opening brace in a multiline string', 'package actor ChatMailbox {\nprivate let text = """\n{\n"""\nvar runner: TurnRunner\n}'],
  ['closing brace in a multiline string', 'package actor ChatMailbox {\nprivate let text = """\n}\n"""\nvar runner: TurnRunner\n}'],
  ['braces and quotes in a raw multiline string', 'package actor ChatMailbox {\nprivate let text = #"""\n"{"\n"""#\nvar runner: TurnRunner\n}'],
]) {
  test(`rejects exposed mailbox state with ${name}`, () => {
    const result = run({ [mailbox]: source });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /\[mailbox-private-state\]/);
  });
}

test('accepts inline private mailbox bindings and braces inside strings', () => {
  const result = run({ [mailbox]: `package actor ChatMailbox { package let chatId: ChatID;
    private let (a, b) = (1, 2); private var \`default\`: TurnRunner
    private let text = """
    } var exposed: TurnRunner {
    """
    package func accept() { let runner = self.runner }
  }` });
  assert.equal(result.status, 0, result.output);
});

for (const declaration of [
  'var exposed: State { state }',
  'package var runningScope: TurnScope? { work.phase.running?.attempt?.scope }',
  'var exposed: State { get { state } }',
  'var exposed: State { _read { yield state } }',
  'var exposed: State\n{\nstate\n}',
  'var exposed: State { let copy = state; return copy }',
  'var exposed: State { let set = state; return set }',
  'var exposed: String { "set { _modify { didSet {" }',
  'var exposed: State { get async throws { try await load() } }',
  'package func queue() -> State { state }',
]) {
  test(`accepts read-only mailbox projections: ${declaration}`, () => {
    const result = run({ [mailbox]: `package actor ChatMailbox {\n${declaration}\n}` });
    assert.equal(result.status, 0, result.output);
  });
}

test('accepts private mailbox state, its immutable identity, and method locals', () => {
  const result = run({ [mailbox]: `package actor ChatMailbox {
    package let chatId: ChatID
    private let runner: TurnRunner
    @ObservationIgnored private lazy var state = State {
      let local = State()
      return local
    }
    nonisolated private let clock: Clock
    package func accept() {
      let runner = self.runner
      if let state = state { state.run() }
    }
  }` });
  assert.equal(result.status, 0, result.output);
});

const proofFile = 'apps/ios/EnduragentUITests/ChatProofs.swift';
const featureDirectory = '.claude/skills/verify-ios/features';
const featureFile = `${featureDirectory}/chat.md`;
const featureSections = [
  'Sub-features',
  'How to get to it (user POV)',
  'Driving it with sim.mjs and XCUITest',
  'Gotchas',
];
function feature(references, sections = featureSections) {
  return `# Chat\n${references}\n${sections.map(section => `## ${section}\n`).join('\n')}`;
}
const chatProof = 'final class ChatProof: XCTestCase { func testReply() {} }';

for (const [name, files, rule] of [
  ['unmapped proof', {
    [proofFile]: `${chatProof}\nfinal class StopProof: XCTestCase { func testStop() {} }`,
    [featureFile]: feature('ChatProof/testReply'),
  }, 'feature-proof-unmapped'],
  ['README-only mapping', {
    [proofFile]: chatProof,
    [`${featureDirectory}/README.md`]: 'ChatProof/testReply',
    [featureFile]: feature('The conversation.'),
  }, 'feature-proof-unmapped'],
  ['unknown proof reference', {
    [proofFile]: chatProof,
    [featureFile]: feature('ChatProof/testReply MissingProof'),
  }, 'feature-proof-reference'],
  ['unknown README probe reference', {
    [proofFile]: chatProof,
    [`${featureDirectory}/README.md`]: 'MissingProbe',
    [featureFile]: feature('ChatProof/testReply'),
  }, 'feature-proof-reference'],
  ['missing selected method', {
    [proofFile]: chatProof,
    [featureFile]: feature('ChatProof/testMissing'),
  }, 'feature-proof-method'],
  ['method in another proof class', {
    [proofFile]: `${chatProof}\nfinal class StopProof: XCTestCase { func testStop() {} }`,
    [featureFile]: feature('ChatProof/testStop StopProof'),
  }, 'feature-proof-method'],
  ['duplicate proof class', {
    [proofFile]: chatProof,
    'apps/ios/EnduragentUITests/OtherProofs.swift': chatProof,
    [featureFile]: feature('ChatProof/testReply'),
  }, 'feature-proof-duplicate'],
  ['missing feature section', {
    [proofFile]: chatProof,
    [featureFile]: feature('ChatProof', featureSections.slice(0, -1)),
  }, 'feature-proof-sections'],
  ['reordered feature sections', {
    [proofFile]: chatProof,
    [featureFile]: feature('ChatProof', featureSections.toReversed()),
  }, 'feature-proof-sections'],
  ['extra feature section', {
    [proofFile]: chatProof,
    [featureFile]: feature('ChatProof', [...featureSections, 'Other']),
  }, 'feature-proof-sections'],
]) {
  test(`rejects ${name}`, () => {
    const result = run(files);
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, new RegExp(`\\[${rule}\\]`));
  });
}

test('accepts proofs and probes mapped across feature files with valid selectors', () => {
  const result = run({
    [proofFile]: `${chatProof}\nfinal class StopProof: XCTestCase { func testStop() {} }`,
    'apps/ios/EnduragentUITests/LaunchProbes.swift': 'final class LaunchProbe: XCTestCase { func testLaunch() {} }',
    [featureFile]: feature('ChatProof/testReply StopProof').replaceAll('\n', '\r\n'),
    [`${featureDirectory}/launch.md`]: feature('LaunchProbe/testLaunch'),
    [`${featureDirectory}/README.md`]: '# Proof map\nChatProof StopProof/testStop LaunchProbe',
  });
  assert.equal(result.status, 0, result.output);
});

for (const field of ['errorLine', 'fixtureFeedback']) {
  for (const [name, filename, value] of [
    ['ordinary view', 'ChatView.swift', `import SwiftUI\nstruct ChatView: View { var body: some View { Text(model.${field}) } }`],
    ['view without the View filename suffix', 'FeedbackRow.swift', `import SwiftUI\nstruct FeedbackRow: View { var body: some View { Text(model.${field}) } }`],
    ['unguarded DebugView', 'FixtureFeedbackDebugView.swift', `import SwiftUI\nstruct FixtureFeedbackDebugView: View { var body: some View { Text(model.${field}) } }`],
    ['DebugView release branch', 'FixtureFeedbackDebugView.swift', `#if DEBUG\nimport SwiftUI\n#else\nstruct FixtureFeedbackDebugView: View { var body: some View { Text(model.${field}) } }\n#endif`],
    ['DebugView after a closed debug guard', 'FixtureFeedbackDebugView.swift', `#if DEBUG\nimport SwiftUI\n#endif\nstruct FixtureFeedbackDebugView: View { var body: some View { Text(model.${field}) } }\n#if DEBUG\n#endif`],
  ]) {
    test(`rejects ${field} in ${name}`, () => {
      const result = run({ [`apps/ios/Enduragent/Chat/${filename}`]: value });
      assert.equal(result.status, 1, result.output);
      assert.match(result.output, /\[fixture-feedback-debug-only\]/);
    });
  }
}

test('accepts fixture feedback in a guarded DebugView and its model', () => {
  const result = run({
    'apps/ios/Enduragent/Chat/FixtureFeedbackDebugView.swift': '#if DEBUG\nimport SwiftUI\nstruct FixtureFeedbackDebugView: View { var body: some View { Text(model.fixtureFeedback) } }\n#endif',
    'apps/ios/Enduragent/App/ShellModel.swift': 'import Foundation\nfinal class ShellModel { var fixtureFeedback: String? }',
  });
  assert.equal(result.status, 0, result.output);
});

for (const source of [
  'let launch = FixtureLaunch.firstWeek()',
  '#if DEBUG\nlet debug = true\n#else\nlet launch = FixtureLaunch.firstWeek()\n#endif',
  '#if DEBUG\nlet debug = true\n#endif\nlet launch = FixtureLaunch.firstWeek()',
  '#if DEBUG || os(iOS)\nlet launch = FixtureLaunch.firstWeek()\n#endif',
]) {
  test(`rejects FixtureLaunch outside DEBUG: ${source}`, () => {
    const result = run({ 'apps/ios/Enduragent/App/AppLaunch.swift': source });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /\[fixture-launch-debug-only\]/);
  });
}

test('accepts FixtureLaunch in a nested DEBUG guard', () => {
  const result = run({
    'apps/ios/Enduragent/App/AppLaunch.swift': 'import Foundation\n#if DEBUG\n#if os(iOS)\nlet launch = FixtureLaunch.firstWeek()\n#else\nlet launch = FixtureLaunch.firstWeek()\n#endif\n#endif\nlet live = true',
  });
  assert.equal(result.status, 0, result.output);
});

const recordSource = 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Records/Body.swift';
for (const declaration of [
  'public struct Body {}',
  'public enum Body { case sample }',
  'public\nextension Body {}',
  'public private(set) var value: Int',
  'open class Body {}',
  '@_spi(Testing) public struct Body {}',
  '@_spi(Testing) package struct Body {}',
]) {
  test(`rejects record access declaration ${declaration}`, () => {
    const result = run({ [recordSource]: declaration });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /\[records-package-only\]/);
  });
}

test('accepts package and internal records and public handles outside Records', () => {
  const result = run({
    [recordSource]: 'package struct Body { package var value: Int }\nstruct InternalBody {}',
    'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/CoachPorts.swift':
      'public struct RecordStore {}',
    'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Diagnostics/RecordSyncProbe.swift':
      '#if DEBUG\npublic struct RecordSyncProbe {}\n#endif',
  });
  assert.equal(result.status, 0, result.output);
});

for (const declaration of [
  'final class Duplicate: SecretStore, @unchecked Sendable {}',
  'struct Duplicate: Sendable, SecretStore {}',
  'extension Duplicate: SecretStore {}',
  'extension Outer.Inner: SecretStore {}',
  'struct Duplicate<S: Sendable>: SecretStore where S: Equatable {}',
  'struct Duplicate<S: Collection>: SecretStore where S.Element: SecretStore {}',
]) {
  test(`rejects a second secret store: ${declaration}`, () => {
    const result = run({ 'apps/ios/Store.swift': declaration });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /single-secret-store/);
  });
}

test('accepts the real secret store and fixture backings', () => {
  const result = run({
    'apps/ios/Store.swift': 'struct ICloudKeychainStore: SecretStore {}',
    'apps/ios/Backing.swift': 'final class FixtureSecretStoreBacking: SecretStoreBacking {}',
  });
  assert.equal(result.status, 0, result.output);
});

for (const declaration of [
  'struct Box<S: SecretStore> {}',
  'struct Box<S> where S: SecretStore {}',
  'struct Box<S: SecretStore>: Sendable {}',
  'struct Box<S>: Sendable where S: SecretStore {}',
  'extension Box: Equatable where S: SecretStore {}',
  'struct Box<S: Collection<SecretStore>>: Sendable {}',
]) {
  test(`accepts a secret store constraint: ${declaration}`, () => {
    const result = run({ 'apps/ios/Box.swift': declaration });
    assert.equal(result.status, 0, result.output);
  });
}

test('accepts checked app conversions and string parsing', () => {
  const result = run({
    'apps/ios/Enduragent/App/Example.swift': 'let rounded = Int(exactly: value.rounded())\nlet parsed = Int(raw)',
  });
  assert.equal(result.status, 0, result.output);
});

test('allows SQLite stores only in the committed v1 upgrade scenarios', () => {
  const sqlite = Buffer.from('SQLite format 3\0fixture');
  const base = 'apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures/v1-upgrade';
  for (const scenario of ['history', 'review']) {
    for (const name of ['synced', 'local']) {
      const result = run({ [`${base}/${scenario}/${name}-records.store`]: sqlite });
      assert.equal(result.status, 0, result.output);
    }
  }
  for (const [file, bytes] of [
    [`${base}/other/synced-records.store`, sqlite],
    [`${base}/history/arbitrary.store`, sqlite],
    [`${base}/history/synced-records.store`, Buffer.from('arbitrary\0binary')],
  ]) {
    const result = run({ [file]: bytes });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /unexpected-binary/);
  }
});
