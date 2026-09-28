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
for (const [name, file, value, code] of [
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
  ['literal confirmation copy', 'apps/ios/Enduragent/App/ShellModel.swift', 'confirmLine = "That proposal expired."', 'uncatalogued-confirmation'],
  ['interpolated confirmation copy', 'apps/ios/Enduragent/App/ShellModel.swift', 'confirmLine = "Done — \\(summary)."', 'uncatalogued-confirmation'],
  ['raw confirmation copy', 'apps/ios/Enduragent/App/ShellModel.swift', 'confirmLine = #"That proposal expired."#', 'uncatalogued-confirmation'],
  ['device-only confirmation language', 'apps/ios/Enduragent/App/ShellModel.swift', 'confirmLine = builder.phrasebook.say(Catalog.coachConfirmationExpired, [:])', 'device-only-phrasebook'],
  ['device-only review language', 'apps/ios/Enduragent/Chat/ConfirmedPreviewCard.swift', 'Text(model.builder.phrasebook.say(notice.key, notice.vars))', 'device-only-phrasebook'],
  ['device-only review outcome language', 'apps/ios/Enduragent/Chat/ChatView.swift', 'Text(notice.sentence(in: model.builder.phrasebook))', 'device-only-phrasebook'],
  ['exposed mailbox ledger:', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'let ledger: Ledger', 'mailbox-private-state'],
  ['exposed mailbox clock:', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'let clock: any Clock', 'mailbox-private-state'],
  ['exposed mailbox process:', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'let process: ProcessID', 'mailbox-private-state'],
  ['exposed mailbox records:', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'let records: ChatRecords', 'mailbox-private-state'],
  ['exposed mailbox work', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'let work = MailboxQueue()', 'mailbox-private-state'],
  ['exposed mailbox interruption', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'let interruption = Interruption()', 'mailbox-private-state'],
  ['exposed mailbox var', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'private(set) var live: LiveAttempt?', 'mailbox-private-state'],
  ['exposed mailbox var', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'private(set) var finishedAway: Set<TurnID> = []', 'mailbox-private-state'],
  ['exposed mailbox lazy', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'private(set) lazy var waits = RetryWaits()', 'mailbox-private-state'],
  ['exposed mailbox door', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'let door = Turnstile()', 'mailbox-private-state'],
  ['exposed mailbox pass()', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'func pass() {}', 'mailbox-private-state'],
  ['mailbox modifier fileprivate let ledger: Ledger', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'fileprivate let ledger: Ledger', 'mailbox-private-state'],
  ['mailbox modifier open var work: MailboxQueue', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'open var work: MailboxQueue', 'mailbox-private-state'],
  ['mailbox modifier public nonisolated let clock: any Clock', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'public nonisolated let clock: any Clock', 'mailbox-private-state'],
  ['mailbox modifier package(set) var live: LiveAttempt?', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', 'package(set) var live: LiveAttempt?', 'mailbox-private-state'],
  ['mailbox modifier @ObservationIgnored fileprivate var interruption: Interruption', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', '@ObservationIgnored fileprivate var interruption: Interruption', 'mailbox-private-state'],
  ['mailbox modifier @ObservationIgnored public private(set) var waits: RetryWaits', 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift', '@ObservationIgnored public private(set) var waits: RetryWaits', 'mailbox-private-state'],
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

test('accepts catalogued confirmation copy and debug-only literals', () => {
  const result = run({
    'apps/ios/Enduragent/App/ShellModel.swift': 'confirmLine = phrasebook.say(Catalog.coachConfirmationExpired, [:])',
    'apps/ios/Enduragent/Credits/CredentialsDebugView.swift': '#if DEBUG\nconfirmLine = "Debug result"\n#endif',
  });
  assert.equal(result.status, 0, result.output);
});

test('accepts private mailbox declarations with attributes and modifiers', () => {
  const result = run({
    'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift':
      '@ObservationIgnored private lazy var waits = RetryWaits()\nnonisolated private let clock: Clock',
  });
  assert.equal(result.status, 0, result.output);
});
