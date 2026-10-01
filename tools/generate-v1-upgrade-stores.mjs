import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const commit = '82254bbda75ba79b0156d7efd3deac223489b2b0';
const scratch = mkdtempSync(join(tmpdir(), 'enduragent-p47-v1-'));
const destination = join(root, 'apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures/v1-upgrade');
try {
  const archive = execFileSync('git', ['archive', commit, 'apps/ios/Packages/EnduragentCoach', 'apps/ios/Enduragent/Fixtures/FirstWeekFixture.swift'], { cwd: root, maxBuffer: 16 * 1024 * 1024 });
  execFileSync('tar', ['-x', '-C', scratch], { input: archive });
  const packagePath = join(scratch, 'apps/ios/Packages/EnduragentCoach');
  const tests = join(packagePath, 'Tests/EnduragentCoachTests');
  cpSync(join(root, 'tools/fixtures/V1UpgradeStoreSeed.swift'), join(tests, 'V1UpgradeStoreSeed.swift'));
  cpSync(join(scratch, 'apps/ios/Enduragent/Fixtures/FirstWeekFixture.swift'), join(tests, 'FirstWeekFixture.swift'));
  const generated = join(scratch, 'stores');
  execFileSync('swift', ['test', '--disable-sandbox', '--package-path', packagePath, '--filter', 'V1UpgradeStoreSeed'], {
    env: { ...process.env, OPENROUTER_API_KEY: '', INTERVALS_API_KEY: '', V1_UPGRADE_DESTINATION: generated },
    stdio: 'inherit',
  });
  mkdirSync(destination, { recursive: true });
  for (const scenario of ['history', 'review']) {
    const output = join(destination, scenario);
    rmSync(output, { recursive: true, force: true });
    mkdirSync(output);
    for (const name of readdirSync(join(generated, scenario)).filter(name => name.endsWith('.store'))) {
      const source = join(generated, scenario, name);
      execFileSync('sqlite3', [source, 'PRAGMA wal_checkpoint(TRUNCATE);']);
      cpSync(source, join(output, name));
    }
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
