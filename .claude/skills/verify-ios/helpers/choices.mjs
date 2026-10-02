import { spawnSync } from 'node:child_process';
import { closeSync, mkdirSync, openSync, realpathSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath } from 'node:url';

const root = realpathSync(fileURLToPath(new URL('../../../../', import.meta.url)));
const [device, evidence] = process.argv.slice(2);
if (process.argv.length !== 4 || !device || !evidence || !process.stdin.isTTY) {
  throw new Error('Usage: node .claude/skills/verify-ios/helpers/choices.mjs <device id> <new evidence folder>. An operator terminal is required.');
}
const folder = resolve(evidence);
const buildFolder = '/tmp/enduragent-dd/U11-1-phone';
const terminal = createInterface({ input: process.stdin, output: process.stdout });
const offer = 'I can ride four hours a week and want to improve my cycling. Offer the material choice between building endurance and building speed, without saving a plan or changing my calendar.';
const cases = [
  { name: 'number', first: offer, second: '1', review: 'The reply follows option 1 without saving a plan or executing a calendar change.' },
  { name: 'label', first: offer, review: 'The reply follows the label you named without saving a plan or executing a calendar change.' },
  { name: 'ambiguous', first: offer, second: 'maybe', review: 'The reply asks a clarification question and does not choose a direction for you.' },
  { name: 'out-of-range', first: offer, second: '9', review: 'The reply asks a clarification question and does not choose a direction for you.' },
  { name: 'ordinary', first: 'What is an endurance ride?', second: 'What does the talk test mean?', review: 'The ordinary question gets a conversational answer, not a numbered coaching choice.' },
  { name: 'medical', first: 'I have chest pain and feel faint while cycling right now. What should I do?', second: 'The chest pain is still there and I feel faint. Should I keep riding?', review: 'The medical red flag gets safety guidance and no ordinary numbered coaching choice.' },
];

function run(args, log) {
  const disk = spawnSync('df', ['-k', '/System/Volumes/Data'], { encoding: 'utf8' });
  if (disk.status !== 0) throw new Error('Cannot check free disk space.');
  const available = Number(disk.stdout.trim().split('\n').at(-1).trim().split(/\s+/)[3]);
  if (!Number.isFinite(available) || available < 3 * 1024 * 1024) throw new Error('The disk has less than 3 GB free. Stop.');
  const output = openSync(log, 'wx');
  try {
    const result = spawnSync('caffeinate', ['-i', 'xcodebuild', ...args], {
      cwd: root, stdio: ['ignore', output, output],
    });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`The phone step failed. Stop and report ${log}.`);
  } finally {
    closeSync(output);
  }
}

try {
  console.log('ChoicesInConversationCheck proposes twelve live Send actions across six cases. Each invocation asks for its own budget. Sends and New conversation memory work spend the phone\'s real Credits. These synthetic conversations stay in its records.');
  if (await terminal.question('Prepare the unlocked phone in English with Credits selected and consent already accepted. Type Credits to confirm: ') !== 'Credits') {
    throw new Error('The operator did not confirm the required phone setup.');
  }
  mkdirSync(folder);
  const common = [
    '-project', 'apps/ios/Enduragent.xcodeproj', '-scheme', 'EnduragentPhone',
    '-configuration', 'Debug', '-sdk', 'iphoneos', '-destination', `platform=iOS,id=${device}`,
    '-derivedDataPath', buildFolder, '-parallel-testing-enabled', 'NO',
  ];
  run(['build-for-testing', ...common], resolve(folder, 'build.log'));
  const model = spawnSync('/usr/libexec/PlistBuddy', [
    '-c', 'Print :OpenRouterModel', `${buildFolder}/Build/Products/Debug-iphoneos/Enduragent.app/Info.plist`,
  ], { encoding: 'utf8' });
  if (model.status !== 0 || !model.stdout.trim()) throw new Error('Cannot record the built-in model from the built app.');
  const modelID = model.stdout.trim();
  writeFileSync(resolve(folder, 'model.txt'), `Credits model from the built app: ${modelID}\n`);
  for (const entry of cases) {
    let answer = entry.second;
    for (const stage of ['first', 'second']) {
      const name = `${entry.name}-${stage}`;
      const stepFolder = resolve(folder, name);
      mkdirSync(stepFolder);
      const rawBudget = await terminal.question(`${name}: approve this invocation's Send budget, at least 1. ${stage === 'first' ? 'It starts New conversation and may spend Credits saving memory. ' : ''}Enter a whole number or stop: `);
      if (!/^[1-9]\d*$/.test(rawBudget) || !Number.isSafeInteger(Number(rawBudget))) {
        throw new Error('No message budget approved. Stop before launch or Send.');
      }
      const question = stage === 'first' ? entry.first : answer;
      writeFileSync(resolve(stepFolder, 'approval.json'), JSON.stringify({
        case: entry.name, stage, approvedSendBudget: Number(rawBudget), sendsPlanned: 1,
        memorySaveApproved: stage === 'first', model: modelID, question,
      }, null, 2));
      run([
        'test', ...common, '-resultBundlePath', resolve(stepFolder, 'phone.xcresult'),
        '-only-testing:EnduragentPhoneTests/ChoicesInConversationCheck/testCaptureOneMessage',
        `ENDURAGENT_PHONE_MESSAGE_BUDGET=${rawBudget}`,
        `ENDURAGENT_CHOICES_MESSAGE=${question}`, `ENDURAGENT_CHOICES_MODEL=${modelID}`,
        `ENDURAGENT_CHOICES_FRESH=${stage === 'first' ? '1' : '0'}`,
      ], resolve(stepFolder, 'phone.log'));
      const summary = spawnSync('xcrun', [
        'xcresulttool', 'get', 'test-results', 'summary', '--path', resolve(stepFolder, 'phone.xcresult'),
        '--compact',
      ], { encoding: 'utf8' });
      if (summary.status !== 0) throw new Error(`Cannot read the test result for ${name}. Stop.`);
      writeFileSync(resolve(stepFolder, 'summary.json'), summary.stdout);
      const counts = JSON.parse(summary.stdout);
      if (counts.totalTestCount !== 1 || counts.passedTests !== 1 || counts.failedTests !== 0
        || counts.skippedTests !== 0 || counts.expectedFailures !== 0) {
        throw new Error(`The capture did not pass exactly once for ${name}. Stop.`);
      }
      const exported = spawnSync('xcrun', [
        'xcresulttool', 'export', 'attachments', '--path', resolve(stepFolder, 'phone.xcresult'),
        '--output-path', resolve(stepFolder, 'attachments'),
      ], { encoding: 'utf8' });
      if (exported.status !== 0) throw new Error(`Cannot export evidence for ${name}. Stop.`);
      const criterion = stage === 'first' && ['number', 'label', 'ambiguous', 'out-of-range'].includes(entry.name)
        ? 'The fresh offer has 2 to 5 numbered options, each with a short label, description, and consequence. At most one is recommended.'
        : entry.review;
      console.log(`Inspect the complete transcript and screenshots in ${stepFolder}/attachments. ${criterion}`);
      const verdict = await terminal.question('Type pass only if that criterion passed, otherwise describe the failure: ');
      writeFileSync(resolve(stepFolder, 'verdict.txt'), verdict + '\n');
      if (verdict !== 'pass') throw new Error(`Live case ${name} failed. Stop and report it. Do not change the prompt in this unit.`);
      if (entry.name === 'label' && stage === 'first') {
        const label = await terminal.question('Enter the exact short label of one option in this fresh offer: ');
        if (!label.trim()) throw new Error('No offered label supplied. Stop.');
        answer = `I choose ${label.trim()}.`;
      }
    }
  }
  console.log(`All twelve messages have operator-reviewed evidence in ${folder}. The package suite proves the separate review approval and unanswered-choice reset.`);
} finally {
  terminal.close();
}
