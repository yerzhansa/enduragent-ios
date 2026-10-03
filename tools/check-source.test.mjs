import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const checker = fileURLToPath(new URL('./check-source.mjs', import.meta.url));
function run(files, tracked = true, links = {}) {
  const root = mkdtempSync(join(tmpdir(), 'ios-source-check-'));
  try {
    execFileSync('git', ['init', '-q', root]);
    for (const [file, content] of Object.entries(files)) {
      mkdirSync(dirname(join(root, file)), { recursive: true });
      writeFileSync(join(root, file), content);
    }
    for (const [file, target] of Object.entries(links)) {
      mkdirSync(dirname(join(root, file)), { recursive: true });
      symlinkSync(typeof target === 'function' ? target(root) : target, join(root, file));
    }
    if (tracked) execFileSync('git', ['-C', root, 'add', '-f', '--', ...(Array.isArray(tracked) ? tracked : ['.'])]);
    const result = spawnSync(process.execPath, [checker, '--root', root], { encoding: 'utf8', timeout: 10000 });
    return { status: result.status, output: result.stdout + result.stderr };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

for (const [name, files, links] of [
  ['a relative skill-directory link to tracked content', {
    '.agents/skills/check/SKILL.md': '# Check\n',
  }, { '.claude/skills': '../.agents/skills' }],
  ['a relative link to a tracked file', { 'payload.txt': 'technical CTL' }, { 'first.md': 'payload.txt' }],
  ['a tracked two-link chain inside the repository', { 'payload.txt': 'content' }, { first: 'second', second: 'payload.txt' }],
  ['a tracked directory link in a target path', { 'folder/payload.txt': 'content' }, { first: 'second/payload.txt', second: 'folder' }],
  ['parent traversal after resolving a directory link', {
    'nested/payload.txt': 'content', 'nested/deep/keep.txt': 'content',
  }, { first: 'second/../payload.txt', second: 'nested/deep' }],
]) {
  test(`accepts ${name} without reading the link entry as content`, () => {
    const result = run(files, true, links);
    assert.equal(result.status, 0, result.output);
  });
}

for (const [name, files, links, tracked = true] of [
  ['an absolute link to tracked content inside the repository', { 'payload.txt': 'content' }, { first: root => join(root, 'payload.txt') }],
  ['a relative link outside the repository', {}, { first: '..' }],
  ['a dangling link', {}, { first: 'missing.txt' }],
  ['a link to an untracked file', { 'payload.txt': 'content' }, { first: 'payload.txt' }, ['first']],
  ['a link to a directory containing only untracked files', { 'folder/payload.txt': 'content' }, { first: 'folder' }, ['first']],
  ['a tracked two-link chain ending outside the repository', {}, { first: 'second', second: '..' }],
  ['an untracked intermediate link to tracked content', { 'payload.txt': 'content' }, { first: 'second', second: 'payload.txt' }, ['first', 'payload.txt']],
  ['an absolute intermediate link to tracked content', { 'payload.txt': 'content' }, { first: 'second', second: root => join(root, 'payload.txt') }],
  ['a cyclic link chain', {}, { first: 'second', second: 'first' }],
]) {
  test(`rejects ${name} as an unsafe path`, () => {
    const result = run(files, tracked, links);
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /"first" \[unsafe-path\]/);
  });
}

const fixture = 'apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures/intervals-activity.json';
const sensitiveID = 'i' + '8'.repeat(8);
const activityID = '9'.repeat(11);
const recordModel = 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Records/StoredAthleteRecord.swift';

const xcodeProject = 'apps/ios/Enduragent.xcodeproj/project.pbxproj';
const proofEntitlements = 'apps/ios/Enduragent/KeychainProof.entitlements';
const sharedBuildSettings = {
  DEVELOPMENT_TEAM: 'FA494ACVTF', CODE_SIGN_STYLE: 'Automatic', SWIFT_VERSION: '6.0',
};
function phoneProjectFiles(settings = sharedBuildSettings, entitlements = {
  'keychain-access-groups': ['$(AppIdentifierPrefix)icu.enduragent.keychainproof'],
}) {
  return {
    [xcodeProject]: JSON.stringify({
      rootObject: 'project',
      objects: {
        project: { buildConfigurationList: 'projectConfigs', targets: ['app', 'phoneTests'] },
        projectConfigs: { buildConfigurations: ['projectProof'] },
        projectProof: { name: 'DebugKeychainProof', buildSettings: settings },
        app: { productType: 'com.apple.product-type.application', buildConfigurationList: 'appConfigs' },
        appConfigs: { buildConfigurations: ['appProof'] },
        appProof: { name: 'DebugKeychainProof', buildSettings: {
          ...sharedBuildSettings,
          PRODUCT_BUNDLE_IDENTIFIER: 'icu.enduragent.keychainproof',
          CODE_SIGN_ENTITLEMENTS: 'Enduragent/KeychainProof.entitlements',
        } },
        phoneTests: { productType: 'com.apple.product-type.bundle.ui-testing', buildConfigurationList: 'testConfigs' },
        testConfigs: { buildConfigurations: ['testProof'] },
        testProof: { name: 'DebugKeychainProof', buildSettings: {} },
      },
    }),
    [proofEntitlements]: JSON.stringify(entitlements),
  };
}

test('accepts isolated proof entitlements and inherited phone-test settings', () => {
  const result = run(phoneProjectFiles());
  assert.equal(result.status, 0, result.output);
});

for (const entitlements of [
  { 'keychain-access-groups': ['$(AppIdentifierPrefix)icu.enduragent.app'] },
  {
    'keychain-access-groups': ['$(AppIdentifierPrefix)icu.enduragent.keychainproof'],
    'com.apple.developer.icloud-container-identifiers': ['iCloud.icu.enduragent.ios'],
    'com.apple.developer.icloud-services': ['CloudKit'],
  },
]) {
  test(`rejects proof access to ordinary storage: ${JSON.stringify(entitlements)}`, () => {
    const result = run(phoneProjectFiles(sharedBuildSettings, entitlements));
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /keychain-proof-storage-isolation/);
  });
}

for (const setting of Object.keys(sharedBuildSettings)) {
  test(`rejects dropped shared phone-test settings: ${setting}`, () => {
    const settings = { ...sharedBuildSettings };
    delete settings[setting];
    const result = run(phoneProjectFiles(settings));
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /xcode-shared-build-settings/);
  });
}

const navigationRoot = 'apps/ios/Enduragent/Chat/ChatView.swift';
const navigationChild = 'apps/ios/Enduragent/Settings/SettingsView.swift';
const boundNavigation = `struct ChatView: View {
  var body: some View {
    NavigationStack(path: $model.navigation) {
      Text(title).navigationDestination(for: ShellDestination.self) { destination in
        SettingsView(model: model)
      }
    }
  }
}`;

test('rejects a NavigationStack in a pushed view', () => {
  const result = run({
    [navigationRoot]: boundNavigation,
    [navigationChild]: 'struct SettingsView: View { var body: some View { NavigationStack { Text(title) } } }',
  });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /shell-navigation-stack-owner/);
});

test('rejects a NavigationStack reached through a pushed view and its link', () => {
  const result = run({
    [navigationRoot]: boundNavigation,
    [navigationChild]: 'struct SettingsView: View { var body: some View { NavigationLink(title) { RecordsView() } } }',
    'apps/ios/Enduragent/Records/RecordsView.swift': 'struct RecordsView: View { var body: some View { NavigationStack { Text(title) } } }',
  });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /RecordsView.swift.*shell-navigation-stack-owner/);
});

test('rejects a second stack inside the bound shell stack', () => {
  const result = run({
    [navigationRoot]: 'struct ChatView: View { var body: some View { NavigationStack(path: $model.navigation) { NavigationStack { Text(title) } } } }',
  });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /shell-navigation-stack-owner/);
});

test('accepts a sheet owning an inline NavigationStack from a pushed view', () => {
  const result = run({
    [navigationRoot]: boundNavigation,
    [navigationChild]: 'struct SettingsView: View { var body: some View { Text(title).sheet(isPresented: $show) { NavigationStack { Text(title) } } } }',
  });
  assert.equal(result.status, 0, result.output);
});

test('accepts a sheet owning a separate stack view without exempting its pushed sibling', () => {
  const sheet = 'struct SheetView: View { var body: some View { NavigationStack { Text(title) } } }';
  const pushed = 'struct SettingsView: View { var body: some View { Text(title).sheet(item: $selection) { item in SheetView() } } }';
  const result = run({ [navigationRoot]: boundNavigation, [navigationChild]: pushed + sheet });
  assert.equal(result.status, 0, result.output);
  const nested = run({
    [navigationRoot]: boundNavigation,
    [navigationChild]: pushed.replace('Text(title).sheet', 'NavigationStack { Text(title) }.sheet') + sheet,
  });
  assert.equal(nested.status, 1, nested.output);
  assert.match(nested.output, /shell-navigation-stack-owner/);
});

test('rejects a stack outside nested sheets', () => {
  const result = run({
    [navigationRoot]: boundNavigation,
    [navigationChild]: `struct SettingsView: View {
      var body: some View {
        Text(title).sheet(isPresented: $show) {
          NavigationStack { Text(title).sheet(isPresented: $other) { NavigationStack { Text(title) } } }
        }
        NavigationStack { Text(title) }
      }
    }`,
  });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /shell-navigation-stack-owner/);
});

test('accepts independent onboarding stacks and NavigationStack inside a string', () => {
  const result = run({
    [navigationRoot]: boundNavigation,
    [navigationChild]: 'struct SettingsView: View { var body: some View { Text("NavigationStack { RecordsView() }") } }',
    'apps/ios/Enduragent/Onboarding/NoticeView.swift': 'struct NoticeView: View { var body: some View { NavigationStack { Text(title) } } }',
  });
  assert.equal(result.status, 0, result.output);
});

test('rejects app tests deleting fixture folders outside their async owner', () => {
  const result = run({ 'apps/ios/EnduragentTests/FixtureTests.swift': 'deinit { try FileManager.default.removeItem(at: directory) }' });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /app-fixture-folder-ownership/);
});

test('accepts app tests awaiting fixture folder cleanup', () => {
  const result = run({ 'apps/ios/EnduragentTests/FixtureTests.swift': 'try await folder.cleanup { await owners.release() }' });
  assert.equal(result.status, 0, result.output);
});

for (const value of ['let directory = FileManager.default.temporaryDirectory', 'let directory = NSTemporaryDirectory()', 'try AppServices.fixture(launch, defaults: defaults)']) {
  test(`rejects app tests bypassing the shared fixture owner: ${value}`, () => {
    const result = run({ 'apps/ios/EnduragentTests/FixtureTests.swift': value });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /app-fixture-folder-ownership/);
  });
}

test('accepts the shared app fixture owner creating folders and services', () => {
  const result = run({ 'apps/ios/EnduragentTests/FixtureTestScope.swift': 'let directory = try TestTemporaryFolders.make()\ntry AppServices.fixture(launch, defaults: defaults)' });
  assert.equal(result.status, 0, result.output);
});

for (const target of [
  'Packages/EnduragentCoach/Tests/EnduragentCoachTests',
  'EnduragentTests',
  'EnduragentUITests',
  'EnduragentPhoneTests',
]) {
  for (const value of ['FileManager.default.temporaryDirectory', 'NSTemporaryDirectory()', '"/tmp/shared-output"']) {
    test(`rejects tests bypassing the shared temporary folder owner in ${target}: ${value}`, () => {
      const result = run({ [`apps/ios/${target}/FolderTests.swift`]: `let directory = ${value}` });
      assert.equal(result.status, 1, result.output);
      assert.match(result.output, /app-fixture-folder-ownership/);
    });
  }
}

for (const value of ['FileManager.default.temporaryDirectory', 'NSTemporaryDirectory()']) {
  test(`rejects the app fixture scope bypassing shared temporary folder allocation: ${value}`, () => {
    const result = run({ 'apps/ios/EnduragentTests/FixtureTestScope.swift': `let directory = ${value}` });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /app-fixture-folder-ownership/);
  });
}

test('accepts the shared temporary folder helper', () => {
  const result = run({ 'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoachFixtures/TestTemporaryFolders.swift': 'let directory = FileManager.default.temporaryDirectory' });
  assert.equal(result.status, 0, result.output);
});
const ledgerIndexes = String.raw`#Index<StoredAthleteRecord>([\.deviceId, \.hlcWallMs, \.hlcLogical], [\.kind, \.chatId])`;
const ledgerIndexVersion = '@Attribute(hashModifier: "ledger-indexes-v1")';

const testWaitFiles = [
  'apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/WaitSupport.swift',
  'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoachFixtures/WaitSupport.swift',
  'apps/ios/EnduragentTests/WaitSupport.swift',
];
for (const file of testWaitFiles) {
  for (const source of [
    'try await beforeDeadline(within: .seconds(5)) { await event() }',
    'try await beforeDeadline(\nwithin: Duration.milliseconds(20)) { await event() }',
    'let clock = HeldClock(within: .zero)',
    'func wait(within limit: Duration = .seconds(5)) {}',
    'let deadline = ContinuousClock.now + .seconds(5)',
    'let deadline = ContinuousClock().now + Duration.seconds(5)',
    'group.addTask { try await Task.sleep(for: .seconds(10)); return false }',
    'group.addTask {\ntry await Task.sleep(for: Duration.seconds(5))\nreturn nil\n}',
  ]) {
    test(`rejects a literal test hang guard in ${file}: ${source}`, () => {
      const result = run({ [file]: source });
      assert.equal(result.status, 1, result.output);
      assert.match(result.output, /test-hang-guard-duration/);
    });
  }
  test(`accepts named hang guards and explicit subject durations in ${file}`, () => {
    const result = run({ [file]: `
      try await beforeDeadline(within: .hangGuard) { await event() }
      try await beforeDeadline(within: .subject(.milliseconds(20))) { await event() }
      let clock = HeldClock(within: .subject(.zero))
      func wait(within limit: TestWaitLimit = .hangGuard) {}
      let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
      let observation = ContinuousClock.now + TestWaitLimit.subject(.seconds(1)).duration
      group.addTask { try await Task.sleep(for: TestWaitLimit.hangGuard.duration); return false }
      group.addTask { try await Task.sleep(for: TestWaitLimit.subject(.milliseconds(20)).duration); return nil }
      clock.advance(by: .seconds(7))
      try await clock.sleep(for: .seconds(11))
      try await Task.sleep(for: .milliseconds(10))
      let text = "beforeDeadline(within: .seconds(5))"
    ` });
    assert.equal(result.status, 0, result.output);
  });
}

test('leaves UI proof screen waits outside the test hang guard rule', () => {
  const result = run({
    'apps/ios/EnduragentUITests/TutorialHarness.swift': 'let deadline = ContinuousClock.now + .seconds(5)',
    'apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Example.swift': 'func operation(within limit: Duration = .seconds(5)) {}',
  });
  assert.equal(result.status, 0, result.output);
});

for (const source of [
  'while !ready { try await changed.waitUnlessCancelled() }',
  'try await beforeDeadline(within: .hangGuard) { return true }; while !ready { try await changed.waitUnlessCancelled() }',
  'while !ready { try await changed . waitUnlessCancelled () }',
  'while let changed = state.withLock({ state in state.changed }) { try await changed.waitUnlessCancelled() }',
]) {
  test(`rejects an unbounded cancellable gate loop: ${source}`, () => {
    const result = run({ 'apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/WaitSupport.swift': source });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /test-wait-deadline/);
  });
}

const observationWait = `while !condition() {
  await withCheckedContinuation { continuation in
    withObservationTracking {
      if condition() { continuation.resume() }
    } onChange: {
      continuation.resume()
    }
  }
}`;

test('rejects an unbounded observation continuation loop', () => {
  const result = run({ 'apps/ios/EnduragentTests/WaitSupport.swift': observationWait });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /test-wait-deadline/);
});

test('accepts an observation continuation loop inside a deadline', () => {
  const result = run({
    'apps/ios/EnduragentTests/WaitSupport.swift': `try await beforeDeadline(within: .hangGuard, onTimeout: { release() }) { ${observationWait} }`,
  });
  assert.equal(result.status, 0, result.output);
});

for (const source of [
  'try await beforeDeadline(within: .hangGuard) { while !ready { try await changed.waitUnlessCancelled() } }',
  'try await beforeDeadline(within: .hangGuard, onTimeout: { gate.release() }) { while let changed = state.withLock({ state in state.changed }) { try await changed.waitUnlessCancelled() } }',
  'while !ready, ContinuousClock.now < deadline { await Task.yield() }',
]) {
  test(`accepts a bounded gate loop: ${source}`, () => {
    const result = run({ 'apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/WaitSupport.swift': source });
    assert.equal(result.status, 0, result.output);
  });
}

for (const source of [
  'app.launchArguments = ["-EnduragentFixture", "first-week"]',
  'element.waitForExistence(timeout: 8)',
  'XCTWaiter.wait(for: [ready], timeout: 30)',
  'TutorialHarness.wait(element, timeout: 5)',
]) {
  test(`rejects UI proof configuration outside shared helpers: ${source}`, () => {
    const result = run({ 'apps/ios/EnduragentUITests/ExampleProof.swift': source });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /ui-proof-shared-helpers/);
  });
}

test('accepts UI proofs using the argument builder and named waits', () => {
  const result = run({ 'apps/ios/EnduragentUITests/ExampleProof.swift': 'TutorialHarness.launch(app, arguments: FixtureArguments(store: .keep))\nTutorialHarness.wait(element, until: .hittable, within: .turn)' });
  assert.equal(result.status, 0, result.output);
});

for (const identifier of [
  'fixture.expire', 'fixture.historyHead', 'fixture.requestCount',
  'fixture.modelRequestCount', 'debug.records', 'debug.leases',
]) {
  test(`rejects an unscrolled Debug row query: ${identifier}`, () => {
    const result = run({ 'apps/ios/EnduragentUITests/TutorialHarness.swift': `let row = TutorialHarness.named(app, "${identifier}")\nTutorialHarness.wait(row)\nrow.tap()` });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /ui-proof-debug-scrolling/);
  });

  test(`accepts a Debug row through bounded scrolling: ${identifier}`, () => {
    const result = run({ 'apps/ios/EnduragentUITests/TutorialHarness.swift': `let row = TutorialHarness.debugRow(app, "${identifier}", direction: .down)\nXCTAssertEqual(row.label, "expected")\nrow.tap()` });
    assert.equal(result.status, 0, result.output);
  });
}

test('rejects skipped UI proofs', () => {
  const result = run({ 'apps/ios/EnduragentUITests/ExampleProof.swift': 'throw XCTSkip("missing old store")' });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /ui-proof-no-skips/);
});

const upgradeStore = 'apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures/v1-upgrade/history/synced-records.store';
test('accepts committed upgrade SQLite stores', () => {
  const result = run({ [upgradeStore]: Buffer.from('SQLite format 3\0fixture') });
  assert.equal(result.status, 0, result.output);
});

for (const folder of ['pre-vault-5de5c782', 'build-2bbe2ee']) {
  test(`accepts committed historical SQLite stores from ${folder}`, () => {
    const result = run({ [upgradeStore.replace('v1-upgrade/history', folder)]: Buffer.from('SQLite format 3\0fixture') });
    assert.equal(result.status, 0, result.output);
  });
}

test('rejects other binary files in upgrade resources', () => {
  const result = run({ [upgradeStore]: Buffer.from('arbitrary\0binary') });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /unexpected-binary/);
});

test('rejects SQLite stores outside the two upgrade scenarios', () => {
  const result = run({ [upgradeStore.replace('/history/', '/other/')]: Buffer.from('SQLite format 3\0fixture') });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /unexpected-binary/);
});

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
const featureDirectory = '.agents/skills/verify-ios/features';
const featureFile = `${featureDirectory}/chat.md`;
function feature(references) {
  return `# Chat\n${references}\n`;
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

test('rejects the fixtures import outside DEBUG', () => {
  const result = run({
    'apps/ios/Enduragent/App/Example.swift': 'import EnduragentCoachFixtures',
  });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /fixture-launch-debug-only/);
});
