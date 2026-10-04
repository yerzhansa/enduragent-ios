import { spawnSync } from 'node:child_process';
import { closeSync, mkdirSync, openSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath } from 'node:url';

const steps = {
  signin: { test: 'OpenRouterSignInPhoneCheck/testHTTPSCallbackSavesConnection', sends: 0 },
  pick: { test: 'OpenRouterRecoveryPhoneCheck/testPickCatalogModelInSettingsAndKeepAfterRelaunch', sends: 0, model: true },
  tool: { test: 'OpenRouterRecoveryPhoneCheck/testSelectedModelStreamsToolTurn', sends: 1, model: true },
  revoked: { test: 'OpenRouterRecoveryPhoneCheck/testRevokedKeyShowsOneRecoveryPrompt', sends: 1 },
  cancel: { test: 'OpenRouterRecoveryPhoneCheck/testCancelRecoveryKeepsRejectedConnection', sends: 0 },
  recover: { test: 'OpenRouterRecoveryPhoneCheck/testSignInAgainRecoversWithoutLosingConversation', sends: 0, model: true },
  'second-consent': { test: 'OpenRouterRecoveryPhoneCheck/testSecondPhoneRequiresNamedConsentBeforeFirstRequest', sends: 0 },
  locked: { test: 'OpenRouterRecoveryPhoneCheck/testTurnFinishesAcrossOperatorPhoneLock', sends: 1, model: true },
};
const [step, device, evidence] = process.argv.slice(2);
const scenario = steps[step];
if (process.argv.length !== 5 || !scenario || !device || !evidence) {
  throw new Error('Usage: node .agents/skills/verify-ios/helpers/openrouter.mjs <signin|pick|tool|revoked|cancel|recover|second-consent|locked> <device id> <new evidence folder>.');
}
if (!process.stdin.isTTY) throw new Error('An operator terminal is required before approval, build, launch or Send.');
const root = realpathSync(fileURLToPath(new URL('../../../../', import.meta.url)));
const folder = resolve(evidence);
const build = '/tmp/enduragent-dd/U8-3-phone';
const terminal = createInterface({ input: process.stdin, output: process.stdout });

try {
  console.log(`This ${step} invocation plans ${scenario.sends} live Sends. Sends spend Credits or use the connected OpenRouter account and may incur charges. No Try again, New conversation, purchase or calendar Add. A stopped invocation needs a fresh budget.`);
  console.log('At every OpenRouter page automation stops. Handle system alerts by hand, verify openrouter.ai and Enduragent, then sign in, revoke or cancel by hand. No script enters credentials or operates a browser page. Keep screenshots and transcripts local.');
  const budget = await terminal.question(`Approve this invocation's message budget, at least ${scenario.sends}, acknowledging automatic usage charges. Enter a whole number or stop: `);
  if (!/^(0|[1-9]\d*)$/.test(budget) || !Number.isSafeInteger(Number(budget)) || Number(budget) < scenario.sends) {
    throw new Error('No sufficient budget approved. Stop before build, launch or Send.');
  }
  const environment = {
    ENDURAGENT_PHONE_MESSAGE_BUDGET: budget,
    ENDURAGENT_PHONE_CHARGES_ACKNOWLEDGED: 'yes',
  };
  if (scenario.model) {
    const model = await terminal.question(step === 'pick'
      ? 'Enter a different catalog model ID to choose in Settings, with no Send: '
      : 'Enter the exact saved model ID confirmed by the pick step: ');
    if (!model.trim()) throw new Error('No model choice confirmed. Stop.');
    environment.ENDURAGENT_OPENROUTER_MODEL = model.trim();
  }
  if (step === 'pick') {
    environment.ENDURAGENT_OPENROUTER_MODEL_NAME = (await terminal.question('Target catalog model display name: ')).trim();
    environment.ENDURAGENT_OPENROUTER_PROVIDER = (await terminal.question('Target catalog model hosting provider: ')).trim();
    if (!environment.ENDURAGENT_OPENROUTER_MODEL_NAME || !environment.ENDURAGENT_OPENROUTER_PROVIDER) {
      throw new Error('The catalog model name and provider were not supplied. Stop.');
    }
    console.log('The proof taps only that catalog row. If consent appears, read the named model and provider, then accept by hand. The choice must stay marked after relaunch. Nothing is sent.');
  }
  if (step === 'revoked') {
    const revoked = await terminal.question('Revoke only the current test key on OpenRouter by hand. Confirm the correct key and account. Type revoked to proceed: ');
    if (revoked !== 'revoked') throw new Error('Revocation was not confirmed. Stop.');
    environment.ENDURAGENT_OPENROUTER_REVOKED = 'operator-confirmed';
  }
  if (step === 'second-consent') {
    const phones = await terminal.question('Use two updated signed phones on the same Apple ID. Leave the receiver at its first consent for the synced OpenRouter choice. Type ready to confirm: ');
    if (phones !== 'ready') throw new Error('Second-phone setup was not confirmed. Stop.');
    environment.ENDURAGENT_SECOND_PHONE = 'updated-same-apple-id';
    environment.ENDURAGENT_OPENROUTER_MODEL_NAME = (await terminal.question('Selected model display name on the source phone: ')).trim();
    environment.ENDURAGENT_OPENROUTER_PROVIDER = (await terminal.question('Named hosting provider on the source phone: ')).trim();
    if (!environment.ENDURAGENT_OPENROUTER_MODEL_NAME || !environment.ENDURAGENT_OPENROUTER_PROVIDER) {
      throw new Error('The synced consent recipient was not supplied. Stop.');
    }
  }
  if (step === 'locked') {
    console.log('When the turn starts, physically lock the iPhone. Keep it locked until coaching finishes, then unlock it. Inspect the lock screenshot afterward. Home does not prove locked Keychain access.');
  }
  const ready = await terminal.question('Prepare English, the plain signed install, no draft, no unfinished turn or workout review, and the required screen. Read this step in verify-ios. Type ready: ');
  if (ready !== 'ready') throw new Error('The phone setup was not confirmed. Stop.');
  const disk = spawnSync('df', ['-k', '/System/Volumes/Data'], { encoding: 'utf8' });
  if (disk.status !== 0) throw new Error('Cannot check free disk space.');
  const available = Number(disk.stdout.trim().split('\n').at(-1).trim().split(/\s+/)[3]);
  if (!Number.isFinite(available) || available < 3 * 1024 * 1024) throw new Error('The disk has less than 3 GB free. Stop.');
  mkdirSync(folder);
  writeFileSync(resolve(folder, 'approval.json'), JSON.stringify({ step, sendsPlanned: scenario.sends, approvedBudget: Number(budget), chargesAcknowledged: true, model: environment.ENDURAGENT_OPENROUTER_MODEL }, null, 2));
  const output = openSync(resolve(folder, 'phone.log'), 'wx');
  try {
    const result = spawnSync('caffeinate', ['-i', 'xcodebuild', 'test',
      '-project', 'apps/ios/Enduragent.xcodeproj', '-scheme', 'EnduragentPhone',
      '-configuration', 'Debug', '-sdk', 'iphoneos', '-destination', `platform=iOS,id=${device}`,
      '-derivedDataPath', build, '-parallel-testing-enabled', 'NO',
      '-resultBundlePath', resolve(folder, 'phone.xcresult'),
      `-only-testing:EnduragentPhoneTests/${scenario.test}`,
      ...Object.entries(environment).map(([key, value]) => `${key}=${value}`),
    ], { cwd: root, stdio: ['ignore', output, output] });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`The phone proof failed. Stop and report ${folder}/phone.log, Sends used and phone state.`);
  } finally {
    closeSync(output);
    rmSync(build, { recursive: true, force: true });
  }
  const summary = spawnSync('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', resolve(folder, 'phone.xcresult'), '--compact'], { encoding: 'utf8' });
  if (summary.status !== 0) throw new Error('Cannot read the phone result. Stop.');
  writeFileSync(resolve(folder, 'summary.json'), summary.stdout);
  const counts = JSON.parse(summary.stdout);
  if (counts.totalTestCount !== 1 || counts.passedTests !== 1 || counts.failedTests !== 0 || counts.skippedTests !== 0 || counts.expectedFailures !== 0) throw new Error('The selected phone test did not pass exactly once. Stop.');
  const exported = spawnSync('xcrun', ['xcresulttool', 'export', 'attachments', '--path', resolve(folder, 'phone.xcresult'), '--output-path', resolve(folder, 'attachments')], { encoding: 'utf8' });
  if (exported.status !== 0) throw new Error('Cannot export phone attachments. Stop.');
  console.log(`Inspect every screenshot and transcript in ${folder}/attachments. Verify the streamed reply, real tool call, retained earlier messages and selected model. For lock, verify an actual locked screen and a completed turn after unlocking. For sync, verify the selected model and provider match the source phone and consent precedes any Send. Check OpenRouter usage and Credits for accidental fallback. Keep missing evidence pending.`);
  const verdict = await terminal.question('Type pass only after that inspection, otherwise describe the failed criterion: ');
  writeFileSync(resolve(folder, 'verdict.txt'), verdict + '\n');
  if (verdict !== 'pass') throw new Error('Operator review did not pass. Stop. A new invocation needs a new budget.');
  console.log(`Evidence saved in ${folder}. Continue with the next manual checkpoint in verify-ios using a fresh invocation and budget.`);
} finally {
  terminal.close();
}
