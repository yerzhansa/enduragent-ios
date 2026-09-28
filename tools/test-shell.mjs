import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
let revision;
if (args[0] === '--revision') {
  args.shift();
  revision = args.shift();
  if (!revision) throw new Error('--revision requires a git revision');
}
const directory = join(root, '.build', 'shell-tests');
const tests = join(directory, 'Tests', 'ShellTests');
mkdirSync(tests, { recursive: true });
for (const name of ['ShellModel', 'DraftStore', 'AppLaunch']) {
  const path = `apps/ios/Enduragent/App/${name}.swift`;
  const destination = join(tests, `${name}.swift`);
  if (revision) {
    writeFileSync(destination, execFileSync('git', ['-C', root, 'show', `${revision}:${path}`]));
  } else {
    copyFileSync(join(root, path), destination);
  }
}
copyFileSync(join(root, 'tools/shell-tests/HostAdapters.swift'), join(tests, 'HostAdapters.swift'));
const source = readFileSync(join(root, 'apps/ios/EnduragentTests/ShellLanguageTests.swift'), 'utf8');
writeFileSync(join(tests, 'ShellLanguageTests.swift'), source.replace('@testable import Enduragent\n', ''));
writeFileSync(join(directory, 'Package.swift'), `// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "EnduragentShellTests",
  platforms: [.macOS(.v15)],
  dependencies: [.package(path: "../../apps/ios/Packages/EnduragentCoach")],
  targets: [
    .testTarget(
      name: "ShellTests",
      dependencies: [.product(name: "EnduragentCoach", package: "EnduragentCoach")])
  ],
  swiftLanguageModes: [.v6]
)
`);
const result = spawnSync('swift', ['test', '--package-path', directory, ...args], {
  stdio: 'inherit',
});
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
