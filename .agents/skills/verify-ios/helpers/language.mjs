import { spawnSync } from 'node:child_process';
import { closeSync, mkdirSync, openSync, realpathSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath } from 'node:url';

const root = realpathSync(fileURLToPath(new URL('../../../../', import.meta.url)));
const [device, evidence] = process.argv.slice(2);
if (process.argv.length !== 4 || !device || !evidence || !process.stdin.isTTY) {
  throw new Error('Usage: node .agents/skills/verify-ios/helpers/language.mjs <device id> <new evidence folder>. An operator terminal is required.');
}
const folder = resolve(evidence);
const terminal = createInterface({ input: process.stdin, output: process.stdout });

try {
  console.log('LanguageReplyCheck sends four live messages. They spend real Credits or use the connected OpenRouter account. It changes the saved language preference and leaves Automatic selected. No Try again, New conversation or calendar Add.');
  const budget = await terminal.question('Approve this invocation\'s Send budget, at least 4, acknowledging those charges. Enter a whole number or stop: ');
  if (!/^[1-9]\d*$/.test(budget) || !Number.isSafeInteger(Number(budget)) || Number(budget) < 4) {
    throw new Error('No sufficient message budget approved. Stop before build, launch or Send.');
  }
  const prepared = await terminal.question('Prepare the unlocked phone with consent accepted, model access working, no draft or open review, and preferred languages Russian, French, English. Type ready to confirm: ');
  if (prepared !== 'ready') throw new Error('The operator did not confirm the phone setup.');
  const disk = spawnSync('df', ['-k', '/System/Volumes/Data'], { encoding: 'utf8' });
  if (disk.status !== 0) throw new Error('Cannot check free disk space.');
  const available = Number(disk.stdout.trim().split('\n').at(-1).trim().split(/\s+/)[3]);
  if (!Number.isFinite(available) || available < 3 * 1024 * 1024) {
    throw new Error('The disk has less than 3 GB free. Stop.');
  }
  mkdirSync(folder);
  writeFileSync(resolve(folder, 'approval.json'), JSON.stringify({
    approvedSendBudget: Number(budget), sendsPlanned: 4,
    preferredLanguages: ['ru', 'fr', 'en'], chargesAcknowledged: true,
  }, null, 2));
  const output = openSync(resolve(folder, 'phone.log'), 'wx');
  try {
    const result = spawnSync('caffeinate', ['-i', 'xcodebuild', 'test',
      '-project', 'apps/ios/Enduragent.xcodeproj', '-scheme', 'EnduragentPhone',
      '-configuration', 'Debug', '-sdk', 'iphoneos', '-destination', `platform=iOS,id=${device}`,
      '-derivedDataPath', '/tmp/enduragent-dd/U9-2-phone', '-parallel-testing-enabled', 'NO',
      '-resultBundlePath', resolve(folder, 'phone.xcresult'),
      '-only-testing:EnduragentPhoneTests/LanguageReplyCheck/testFrenchRepliesAfterFixedAndAutomaticRelaunch',
      `ENDURAGENT_PHONE_MESSAGE_BUDGET=${budget}`,
    ], { cwd: root, stdio: ['ignore', output, output] });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`The phone proof failed. Stop and report ${folder}/phone.log.`);
  } finally {
    closeSync(output);
  }
  const summary = spawnSync('xcrun', [
    'xcresulttool', 'get', 'test-results', 'summary', '--path', resolve(folder, 'phone.xcresult'), '--compact',
  ], { encoding: 'utf8' });
  if (summary.status !== 0) throw new Error('Cannot read the phone test result. Stop.');
  writeFileSync(resolve(folder, 'summary.json'), summary.stdout);
  const counts = JSON.parse(summary.stdout);
  if (counts.totalTestCount !== 1 || counts.passedTests !== 1 || counts.failedTests !== 0
    || counts.skippedTests !== 0 || counts.expectedFailures !== 0) {
    throw new Error('The phone capture did not pass exactly once. Stop.');
  }
  const exported = spawnSync('xcrun', [
    'xcresulttool', 'export', 'attachments', '--path', resolve(folder, 'phone.xcresult'),
    '--output-path', resolve(folder, 'attachments'),
  ], { encoding: 'utf8' });
  if (exported.status !== 0) throw new Error('Cannot export the phone attachments. Stop.');
  console.log(`Inspect all reply pages and transcripts in ${folder}/attachments. Fixed French after relaunch must answer the English question in French. Automatic after relaunch must answer English, Japanese and /review in French. A notice, empty reply or any non-French generated prose fails this proof.`);
  const verdict = await terminal.question('Type pass only if every live reply meets that rule, otherwise describe the failure: ');
  writeFileSync(resolve(folder, 'verdict.txt'), verdict + '\n');
  if (verdict !== 'pass') throw new Error('The live language proof failed. Stop and report it. A new invocation needs a new budget.');
  console.log(`Operator-reviewed language evidence is saved in ${folder}. The phone remains on Automatic.`);
} finally {
  terminal.close();
}
