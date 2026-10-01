import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fixtures = join(root, 'apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures');
const scenarios = [
  { folder: 'pre-vault-5de5c782', commit: '5de5c782689764543b6d12aa30690912b21f53ee', seed: 'PreVaultStoreSeed' },
  { folder: 'build-2bbe2ee', commit: '2bbe2ee52bb7e8e0df277ae978a89c39d780acf8', seed: 'Build2bbe2eeStoreSeed' },
];

for (const { folder, commit, seed } of scenarios) {
  const scratch = mkdtempSync(join(tmpdir(), 'enduragent-p47-upgrade-'));
  try {
    const archive = execFileSync('git', ['archive', commit, 'apps/ios/Packages/EnduragentCoach', 'apps/ios/Enduragent/Fixtures/FirstWeekFixture.swift'], { cwd: root, maxBuffer: 32 * 1024 * 1024 });
    execFileSync('tar', ['-x', '-C', scratch], { input: archive });
    const packagePath = join(scratch, 'apps/ios/Packages/EnduragentCoach');
    const tests = join(packagePath, 'Tests/EnduragentCoachTests');
    cpSync(join(root, 'tools/fixtures', `${seed}.swift`), join(tests, `${seed}.swift`));
    cpSync(join(scratch, 'apps/ios/Enduragent/Fixtures/FirstWeekFixture.swift'), join(tests, 'FirstWeekFixture.swift'));
    const generated = join(scratch, 'stores');
    execFileSync('swift', ['test', '--disable-sandbox', '--package-path', packagePath, '--filter', seed], {
      env: { ...process.env, OPENROUTER_API_KEY: '', INTERVALS_API_KEY: '', UPGRADE_STORE_DESTINATION: generated },
      stdio: 'inherit',
    });
    const destination = join(fixtures, folder);
    rmSync(destination, { recursive: true, force: true });
    mkdirSync(destination, { recursive: true });
    for (const name of ['synced-records.store', 'local-records.store']) {
      const source = join(generated, name);
      execFileSync('sqlite3', [source, 'PRAGMA wal_checkpoint(TRUNCATE);']);
      cpSync(source, join(destination, name));
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}
