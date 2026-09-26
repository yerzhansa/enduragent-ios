---
name: verify-ios
description: Drive the Enduragent iPhone app, the SwiftUI app in apps/ios, on a dedicated iOS 26 simulator in fixture mode the way an athlete taps through it, and keep screenshots, xcresult bundles, and the fixture request count as proof. Use to prove an iOS UI change, reproduce a phone bug on the simulator, run the XCUITest proofs on an isolated simulator, or compare a screen with the approved native prototypes.
---

# Verify the Enduragent iPhone app

The surface is the iPhone app built from `apps/ios/project.yml`. Every verification run creates its own simulator, `enduragent-verify-<run id>`, from the newest iOS 26 runtime. The default device is iPhone 17e, which is 390 × 844 points, the same viewport as the prototype captures. Never drive a simulator the run did not create. Never drive a physical device.

The app always runs in fixture mode, `-EnduragentFixture first-week`. `AppServices.fixture` swaps intervals.icu, credits, the model transport, the keychain, and the record store for fakes. The fakes keep their state on disk under the app's `Application Support/fixture/` and in the `UserDefaults` suite `icu.enduragent.fixture`, so a relaunch can either wipe it (`-EnduragentFixtureStore fresh`, the default) or reuse it (`-EnduragentFixtureStore keep`). `FixtureBlockingURLProtocol` fails and counts every `URLSession` request. No API key, account, or network is needed.

Every step goes through one helper. Run it by path from the checkout you are verifying. It resolves that checkout from its own location, so it also works when your shell starts somewhere else.

```sh
.claude/skills/verify-ios/helpers/sim.mjs build
.claude/skills/verify-ios/helpers/sim.mjs create onboarding
.claude/skills/verify-ios/helpers/sim.mjs doctor <run id>
.claude/skills/verify-ios/helpers/sim.mjs install <run id>
.claude/skills/verify-ios/helpers/sim.mjs test <run id> FirstConversationProof
.claude/skills/verify-ios/helpers/sim.mjs cleanup <run id>
```

Below, `sim.mjs` means `.claude/skills/verify-ios/helpers/sim.mjs`. `create` prints the run id, for example `2026-09-25-213318-onboarding`. Every later command takes it.

The feature map in [features/README.md](features/README.md) is the recipe for each feature. A proof that drives one convenient entry point is incomplete when the feature file lists others.

## Launch

1. Build once per checkout with `sim.mjs build`. It runs `xcodegen generate --spec apps/ios/project.yml`, then `xcodebuild build-for-testing` with the README flags: the generic simulator destination, `-derivedDataPath DerivedData`, and `CODE_SIGNING_ALLOWED=NO`. It also builds the UI test runner that `test` needs. The log is `DerivedData/verify-ios-build.log`. A clean build took 36 seconds on 2026-09-25. If XcodeGen changes `apps/ios/Enduragent.xcodeproj`, the change belongs in your commit, because `project.yml` changed.
2. Create the run with `sim.mjs create <kebab-slug>`. It creates and boots the simulator, waits for `simctl bootstatus`, sets the status bar to 9:41 with full signal and battery like the prototype captures, sets light appearance, and writes `run.json` into the evidence folder. The first boot takes about a minute.
3. Install with `sim.mjs install <run id>`. Install again after every build.
4. Launch with `sim.mjs launch <run id>`. It runs `xcrun simctl launch --terminate-running-process <udid> icu.enduragent.app -EnduragentFixture first-week -AppleLanguages (en) -AppleLocale en_US -EnduragentFixtureStore fresh` and prints `icu.enduragent.app: <pid>`. The app is ready when `sim.mjs shot <run id> notice` shows the notice text `Training suggestions, not medical advice. Check with a doctor before big changes.` and `Continue`. `sim.mjs launch <run id> --keep` passes `-EnduragentFixtureStore keep` instead, which reopens the app on the state the last launch left: after onboarding and a reply it opens on the chat with the transcript. Other arguments after the run id pass through to the app, for example `-EnduragentFixtureKeychain locked`, which makes every keychain read throw as a locked iPhone would, or `-EnduragentFixtureKeychain empty`, which leaves the fixture keychain without a Credits key.

The first launch on a new simulator can block for minutes while first-boot services run and the home screen still shows blank icons. On 2026-09-25, with the Mac at a load average near 250, it took about six minutes and then succeeded. Check `uptime` before you suspect the app, and let the command finish. Launching again terminates the app and opens it again. Teardown is **Cleanup**.

Two runs can drive side by side, because each has its own simulator and run id. They share the checkout's single build, so never run two builds in the same checkout at once.

## Doctor

Run `sim.mjs doctor [<run id>]` first, and again whenever a screen or command looks wrong. It is read-only. It checks Xcode 26, an iOS 26 runtime, the device type, XcodeGen, the app build and its bundle id `icu.enduragent.app`, that no source under `apps/ios` is newer than the build, the UI test runner, and the prototype captures. With a run id it also checks the evidence folder, that the simulator is booted, that the app is installed, and whether it is running. Exit 0 means the run is worth driving.

- `FAIL stale build` means a source changed after the last build. Run `build`, then `install`.
- `note verify simulator ...` lists every `enduragent-verify-*` simulator. Report the ones your run did not create. Delete only your own.

## Drive

XCUITest finds controls by accessibility identifier. The interactive tool taps by coordinates, so find each control in a fresh screenshot by its visible label and name its identifier from the table below in your report.

**XCUITest proofs.** This is the scripted harness and the default. `apps/ios/EnduragentUITests/TutorialProofs.swift` holds one `XCTestCase` per proof, and `TutorialHarness.swift` holds the launch arguments and the shared steps `completeOnboarding`, `send`, `openSidebar`, and `assertZeroFixtureRequests`. Each feature file names the proofs that cover it. Run them with `sim.mjs test`, described in **UI test run**. A state that no proof reaches gets a new proof in `TutorialProofs.swift`, reviewed with the change it proves. It is Swift, so `pnpm lint:swift` and `pnpm check:format` apply.

**Interactive.** Use this for exploration, paths no proof covers, and parity captures. After `launch`, drive with the Claude Code iOS Simulator `control` tool and pass `device: <udid>` on every call. Its default target is the first booted simulator, which can be the operator's own. `screenshot` returns an image 924 pixels wide, and `tap` takes device points, so multiply a position in that image by 0.422. `text` types into the focused field. The simulator uses the Mac keyboard as a hardware keyboard, so no on-screen keyboard appears. Without that tool there is no tap path outside XCUITest, so write a proof.

| Screen | Handles |
| --- | --- |
| Notice | `notice.continue` |
| Connect | `connect.apiKey`, `connect.connect`, `connect.skip`, `connect.athleteName`, `connect.fitness`, `connect.fatigue`, `connect.form`, `connect.continue` |
| Starter | `starter.progress`, `starter.credits`, `starter.start` |
| Chat | `chat.sidebar` labeled `Menu`, the `New chat` button with no identifier, `chat.composer`, `chat.send`, `chat.working`, `chat.error`, `chat.slash.<command>`, `chat.turn.notice`, `chat.turn.tryAgain`, `chat.turn.buyCredits`, `chat.turn.restorePurchases`, `chat.turn.chooseAccessMethod`, `chat.turn.signInAgain` |
| Workout preview | `chat.preview.cancel`, `chat.preview.add` inside the `Confirmed preview` group |
| Menu sheet | `sidebar.credits`, `sidebar.history`, `sidebar.debug` |
| Credits | `credits.balance`, `credits.pack.<product id>`, `credits.note` |
| History | `history.row.<chat id>` |
| Debug | `fixture.requestCount` |

The fixture athlete is Ada Kovač. The fixed day is 1998-06-15. The connect screen shows `Fitness 42`, `Fatigue 49`, and `Form -7`. The starter grant and the balance are 200 credits. The packs are 500 and 2000 credits with purchases disabled. `FirstWeekFixture.script(for:)` picks the coach reply from the message text. `/review` gets the Saturday group ride summary. Text starting with `Remember that` gets `Noted. I'll remember you ride with a group on Saturdays.` Text containing `endurance ride` gets a workout preview. Anything else gets the week summary.

A message that starts with `fixture:` is a directive to the fakes, typed into `chat.composer` like any message. `FixtureDirector` applies it before the turn starts:

| Message | Effect |
| --- | --- |
| `fixture:slow` | Waits 2 seconds, then streams the week summary one word every 250 ms, so `chat.working` shows for 2 seconds and the growing reply for about eight more. |
| `fixture:hang` | The model never answers. The 30 second watchdog fires, the coach retries once, the watchdog fires again, and the turn fails with `coach.error.providerDown` after about 60 seconds. |
| `fixture:fail 500`, `fixture:fail 401`, `fixture:fail 402`, `fixture:fail 429 7`, `fixture:fail network`, `fixture:fail timeout`, `fixture:fail overflow` | The next model request fails before any reply text with the HTTP status or connection error the directive names, parsed by the same rules as the real transport. `429 7` carries a `retry-after` of 7 seconds. A trailing `xN`, as in `fixture:fail 429 7 x4`, fails the next N requests. The coach retries retryable failures with real waits, so the notice needs `x3` for `500` and `network`, `x2` for `timeout`, and `x4` for `429` and `overflow`. |
| `fixture:memory-then-fail` | The model saves a `schedule` memory section, then the next request fails with a 500. The turn ends with a notice and no `Try again`, because information was saved. |
| `fixture:storage fail-next-append` | Arms the record store so its next write fails. Nothing is sent and the transcript does not change; the next message's turn fails when it saves. |

Every directive keeps `fixture.requestCount` at `0 requests`. Any other message gets the normal scripted reply and clears the slow and hang settings.

## UI test run

```sh
.claude/skills/verify-ios/helpers/sim.mjs test <run id> FirstConversationProof
```

Pass one or more proof classes, or `Class/testMethod`. The helper runs `test-without-building` against the products of `sim.mjs build`, so several test runs share one build. After a source change, run `build` and `install` first. The doctor flags a stale build. The command is:

```sh
xcodebuild test-without-building -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -destination id=<udid> -derivedDataPath DerivedData -parallel-testing-enabled NO -resultBundlePath <evidence>/uitest-<stamp>.xcresult -only-testing:EnduragentUITests/FirstConversationProof
```

`-parallel-testing-enabled NO` stops xcodebuild from cloning the simulator, because a clone would escape cleanup. The result bundle lands at `~/Library/Logs/enduragent-verify/<run id>/uitest-<stamp>.xcresult`. Beside it the helper writes the xcodebuild log `uitest-<stamp>.log`, the summary `uitest-<stamp>-summary.json`, and the exported screenshots in `uitest-<stamp>-attachments/` with `manifest.json`. It prints `Passed` or `Failed` with counts, then one `attachment <test> <name> <path>` line per screenshot, where `<name>` is the name the proof gave `TutorialHarness.attach`. On failure it prints the tail of the log and exits 1. On 2026-09-25 all eleven proofs passed, `FirstConversationProof` alone in 82 seconds and the other ten together in 4 minutes 20 seconds.

To prove state across a kill and reopen, call `TutorialHarness.relaunchKeepingStore(app)` inside one proof. It terminates the app, asserts `.notRunning`, swaps `fresh` for `keep` in the launch arguments, launches, and waits for `.runningForeground`. `RelaunchKeepsChatProof` is the model: onboard, send the week question, relaunch, then assert the question and the reply are back and the notice is not. Assert the screen and content the athlete sees, never only that the app came back. `XCUIDevice.shared.press(.home)` followed by `app.activate()` backgrounds and resumes the app without a kill. The interactive equivalent is `sim.mjs launch <run id> --keep`; without `--keep` the launch wipes the fixture store and opens on the notice.

## Compare with the prototype

The approved prototypes are HTML. Their native-look captures are 390 × 844 PNGs named `native-<prototype>-<state>-<theme>.png` in `~/projects/enduragent/desktop/docs/prototypes/ios/captures-2026-09-25/`. Set `ENDURAGENT_PROTOTYPE_CAPTURES` to use another folder. Parity is by state and copy, not pixels, because SwiftUI system rendering differs from the HTML. Do not add a pixel-diff tool.

1. Drive the app to the state with the interactive harness.
2. Run `sim.mjs parity <run id> <prototype>-<state> <light|dark>`, for example `parity <run id> chat-menu dark`. The helper sets the simulator appearance, waits 1.5 seconds, and writes `parity/<prototype>-<state>-<theme>/` with `prototype.png`, `simulator.png` at 1170 × 2532, and `simulator-390.png` at the prototype's 390 × 844. An unknown state prints every available state. The appearance stays set afterwards.
3. To use a proof screenshot instead, add `--from <attachment png>`. Launch that proof with `TutorialHarness.launch(app, dark: true)` for the dark theme.
4. Read `prototype.png` and `simulator-390.png` together and check each item:
   - The same states exist, and the athlete can reach each one.
   - The same catalog copy appears word for word. Copy comes from `packages/i18n/catalogs/en.json` through `phrasebook.say`.
   - The controls appear in the same order, for example `Cancel` before the confirming control.
   - The same enable rules hold. A control disabled in a prototype state is disabled in the same app state.
5. Report each item as a pass or as the exact mismatch, with both image paths.

| Prototype state | App state today |
| --- | --- |
| `chat-welcome` | Chat right after onboarding, with `Hello, Ada.` or `Hello.` after a skip |
| `chat-menu`, `chat-menu-nosync` | The slash list after typing `/` in `chat.composer`. The nosync state is the same list after `Skip for now`. |
| `chat-new-conversation` | The greeting after `New chat` |
| `review-ready` | The `Confirmed preview` card after a workout request |
| `review-canceled-first` | The chat after `chat.preview.cancel` |
| `chat-working` | Within one second of sending `fixture:slow`: `chat.working` reads `Coach is working…` and no reply text yet |
| `chat-streaming` | About three seconds after sending `fixture:slow`: part of the week summary under the working row |
| `chat-failed` | After `fixture:fail network x3`: `chat.turn.notice` reads `The model provider is having trouble — try again in a few minutes.` above `Try again` |
| `chat-long`, `chat-play`, other `review-*`, `language-*`, `settings-*`, `interruption-*` | No app screen yet |

## Evidence

Each run writes to `~/Library/Logs/enduragent-verify/<run id>/`. Set `ENDURAGENT_VERIFY_RUNS` to move the root. The folder is outside the repository, so no screenshot or result bundle can be committed, and it survives cleanup and worktree removal. It holds:

- `run.json` with the run id, simulator name, udid, device type, runtime, checkout, and `git describe --always --dirty` of the checkout;
- `<label>.png` from `sim.mjs shot <run id> <label>`;
- the UI test files described in **UI test run**;
- `parity/<prototype>-<state>-<theme>/` from `sim.mjs parity`.

The helper never overwrites a file in this folder. Never copy evidence into the repository.

Proof standards:

- Drive the athlete's path by tapping controls from launch onward. Setting `ShellModel` state, calling model methods, and unit tests are not UI proof.
- Capture the action and the resulting state. Take a `shot` before the tap and after the result, or use a proof whose attachment shows the end state.
- Check the side effect beside the pixels. Menu, then Debug, must show `fixture.requestCount` reading `0 requests`. `TutorialHarness.assertZeroFixtureRequests` asserts it. Any other count means a code path escaped the fakes, which is a finding.
- The fixture is the only mock, and it replaces services at the same seam as production, `AppServices`. Fixture mode blocks all `URLSession` traffic, keeps records in a SwiftData store under `Application Support/fixture/` with CloudKit off, writes keys to `FakeSecretStore`, and skips the StoreKit price lookup. A fixture run cannot prove live networking, the real keychain, iCloud sync, or StoreKit prices. Say so when a change touches them.
- Report the feature ID and the entry point with every artifact. Do not report a skipped entry point as verified through another one.

## Cleanup

Run `sim.mjs cleanup <run id>` when the run ends, and after every failed attempt before the next one. It shuts down and deletes `enduragent-verify-<run id>`, which removes the installed app and its data. It confirms the simulator is gone and lists the evidence it kept. Running it twice is safe.

Never run `simctl delete all`, `simctl shutdown all`, or `simctl erase`. Never quit Simulator.app or kill CoreSimulatorService, and never kill a process by name. The operator keeps their own simulators booted, and a parallel run owns its own. `DerivedData/` is a build cache, not evidence.

## Helpers

`helpers/sim.mjs` is a dependency-free Node script. Every command prints what it did and exits non-zero on failure.

| Command | Does |
| --- | --- |
| `doctor [<run id>]` | Read-only readiness check described in **Doctor** |
| `build` | XcodeGen, then `build-for-testing` into `DerivedData` |
| `create <kebab-slug>` | New run id, evidence folder, and booted simulator |
| `install <run id>` | Installs the built app on the run's simulator |
| `launch <run id> [--keep] [app arguments]` | Kills and opens the app in fixture mode; `--keep` reuses the fixture state instead of wiping it |
| `shot <run id> <kebab-label>` | Screenshot to `<evidence>/<label>.png` |
| `test <run id> <proof>...` | UI proofs on the run's simulator, with attachments exported |
| `parity <run id> <prototype>-<state> <light\|dark> [--from <png>]` | Prototype capture beside a simulator screenshot |
| `cleanup <run id>` | Deletes the run's simulator and keeps the evidence |

`ENDURAGENT_SIM_DEVICE` changes the device type. Parity comparisons assume the default iPhone 17e.

Keep the feature map honest as the app changes with `/maintain-verification-skill`.
