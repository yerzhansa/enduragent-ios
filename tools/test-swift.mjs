import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const env = { ...process.env };
delete env.OPENROUTER_API_KEY;
delete env.INTERVALS_API_KEY;
const args = process.argv.slice(2);
const commands = [
  ['swift', ['test', '--package-path', 'apps/ios/Packages/EnduragentCoach', ...args]],
  [process.execPath, ['tools/test-shell.mjs', ...args]],
];
for (const [command, arguments_] of commands) {
  const result = spawnSync(command, arguments_, { cwd: root, env, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exitCode = 1;
}
