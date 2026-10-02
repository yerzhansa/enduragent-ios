---
name: verify-ios
description: Drive the Enduragent iPhone app, the SwiftUI app in apps/ios, on a dedicated iOS 26 simulator in fixture mode the way an athlete taps through it, and keep screenshots, xcresult bundles, and the fixture request count as proof. Use to prove an iOS UI change, reproduce a phone bug on the simulator, run the XCUITest proofs on an isolated simulator, or compare a screen with the approved native prototypes.
---

# Verify the Enduragent iPhone app

The surface is the iPhone app built from `apps/ios/project.yml`. Every simulator verification run creates its own simulator, `enduragent-verify-<run id>`, from the newest iOS 26 runtime. The default device is iPhone 17e, which is 390 × 844 points, the same viewport as the prototype captures. Never drive a simulator the run did not create. Physical-device verification uses only the separate real-phone procedure below.

Simulator proofs run in fixture mode, `-EnduragentFixture first-week`. `AppServices.fixture` swaps intervals.icu, credits, the model transport, the keychain, and the record store for fakes. The fakes keep their state on disk under the app's `Application Support/fixture/` and in the `UserDefaults` suite `icu.enduragent.fixture`, so a relaunch can either wipe it (`-EnduragentFixtureStore fresh`, the default) or reuse it (`-EnduragentFixtureStore keep`). `FixtureBlockingURLProtocol` fails and counts every `URLSession` request. No API key, account, or network is needed.

Every simulator step goes through one helper. Run it by path from the checkout you are verifying. It resolves the source tree from its own location, without git, so an exported tree and a shell started elsewhere both work. Source manifests walk `apps/ios` and omit generated projects and build caches. An export needs no symlink or temporary git repository. Set `ENDURAGENT_VERIFY_REVISION` to the exported commit SHA to record its provenance. Without it, `run.json` says `exported-tree` and records a source digest.

```sh
.claude/skills/verify-ios/helpers/sim.mjs build
.claude/skills/verify-ios/helpers/sim.mjs create onboarding
.claude/skills/verify-ios/helpers/sim.mjs doctor <run id>
.claude/skills/verify-ios/helpers/sim.mjs install <run id>
.claude/skills/verify-ios/helpers/sim.mjs test <run id> FirstConversationProof
.claude/skills/verify-ios/helpers/sim.mjs cleanup <run id>
```

Every command accepts `--build-folder <path>`. The flag overrides `ENDURAGENT_VERIFY_BUILD`; both default to `<tree>/DerivedData`. Use the same folder for build, doctor, install, and test. Milestone 2 builds go under `/tmp/enduragent-dd/`, for example `ENDURAGENT_VERIFY_BUILD=/tmp/enduragent-dd/VSKILL`.

Below, `sim.mjs` means `.claude/skills/verify-ios/helpers/sim.mjs`. `create` prints the run id, for example `2026-10-01-120000-a1b2c3d4-onboarding`. Commands for that simulator take its run id.

The feature map in [features/README.md](features/README.md) is the recipe for each feature. A proof that drives one convenient entry point is incomplete when the feature file lists others.

## Launch

1. Build once per checkout with `sim.mjs build`. It runs `xcodegen generate --spec apps/ios/project.yml`, then `xcodebuild build-for-testing` with the README flags: the generic simulator destination, `-derivedDataPath DerivedData`, and `CODE_SIGNING_ALLOWED=NO`. The build-folder option replaces `DerivedData` in those paths. It also builds the UI test runner that `test` needs. The log is `DerivedData/verify-ios-build.log`. Before it builds, it records the SHA-256 of every source under `apps/ios`, and after a successful build it writes them to `DerivedData/verify-ios-sources.json`. A clean build took 36 seconds on 2026-09-25. Commit generated-project changes when sources or `project.yml` change.
2. Create the run with `sim.mjs create <kebab-slug>`. It creates and boots the simulator, waits for `simctl bootstatus`, sets the status bar to 9:41 with full signal and battery like the prototype captures, sets light appearance, and writes `run.json` into the evidence folder. The first boot takes about a minute.
3. Install with `sim.mjs install <run id>`. Install again after every build.
4. Launch with `sim.mjs launch <run id>`. It runs `xcrun simctl launch --terminate-running-process <udid> icu.enduragent.app -EnduragentFixture first-week -AppleLanguages (en) -AppleLocale en_US -EnduragentFixtureStore fresh` and prints `icu.enduragent.app: <pid>`. The app is ready when `sim.mjs shot <run id> notice` shows the notice text `Training suggestions, not medical advice. Check with a doctor before big changes.` and `Continue`. `sim.mjs launch <run id> --keep` passes `-EnduragentFixtureStore keep` instead, which reopens the app on the state the last launch left: after onboarding and a reply it opens on the chat with the transcript. Other arguments after the run id pass through to the app, for example `-EnduragentFixtureKeychain locked`, which makes every keychain read throw as a locked iPhone would, `-EnduragentFixtureKeychain empty`, which leaves the fixture keychain without a Credits key, `-EnduragentFixtureStore unreadable`, which wipes the fixture and makes the record store fail to open so the app shows `launch.storageUnavailable` instead of the notice, `-EnduragentFixtureCoalescing <milliseconds>`, which replaces the 1.5 second window in which a second message joins the first, `-EnduragentFixtureRecovery unreadable`, which makes the launch recovery's read of earlier claims fail so a reply cut off by a kill stays unsettled, `-EnduragentFixtureHost "expire-after 3"`, which makes the fixture's execution host expire every lease three seconds after it begins, as iOS would when it stops the app's background work, and `-EnduragentFixtureClock 1998-06-16T04:20:00Z`, which starts the fixed clock at that ISO 8601 instant instead of `1998-06-15T08:00:00Z`. XCUITest needs about two seconds between two Send taps, so proofs that need a joined turn, a shot before the reply, or a kill before the claim pass `TutorialHarness.launch(app, coalescingMilliseconds:)`.

The first launch on a new simulator can block for minutes while first-boot services run and the home screen still shows blank icons. On 2026-09-25, with the Mac at a load average near 250, it took about six minutes and then succeeded. Check `uptime` before you suspect the app, and let the command finish. Launching again terminates the app and opens it again. Teardown is **Cleanup**.

Two runs can drive side by side, because each has its own simulator and run id. They share the checkout's single build, so never run two builds in the same checkout at once.

## Doctor

Run `sim.mjs doctor [<run id>]` first, and again whenever a screen or command looks wrong. It is read-only. It checks Xcode 26, an iOS 26 runtime, the device type, XcodeGen, the app build and its bundle id `icu.enduragent.app`, that every source under `apps/ios` has the content the last `sim.mjs build` built, the UI test runner, and the prototype captures. With a run id it also checks the evidence folder, that the simulator is booted, that the app is installed, and whether it is running. Exit 0 means the run is worth driving.

- `FAIL stale build` names the first source whose content differs from the last build, or says the build wrote no source manifest. Run `build`, then `install`. Touching a file without changing it does not fail the check, because Xcode skips unchanged content and does not relink the app. A failing doctor stops the run: fix the cause and rerun doctor before any proof.
- `note verify simulator ...` lists every `enduragent-verify-*` simulator. Report the ones your run did not create. Delete only your own.

## Drive

XCUITest finds controls by accessibility identifier. The interactive tool taps by coordinates, so find each control in a fresh screenshot by its visible label and name its identifier from the table below in your report.

**XCUITest proofs.** This is the scripted harness and the default. In `apps/ios/EnduragentUITests/`, classes ending in `Proof` hold the UI proofs. `sim.mjs suite` discovers them from the Swift sources. `LaunchProbes.swift` holds the timing probes. `TutorialHarness.swift` holds the launch arguments and the shared steps `completeOnboarding`, `send`, `openSettings`, and `assertZeroFixtureRequests`. Each feature file names the proofs that cover it. Run them with `sim.mjs test`, described in **UI test run**. A state that no proof reaches gets a new proof in the file for its feature, reviewed with the change it proves. It is Swift, so `pnpm lint:swift` and `pnpm check:format` apply.

**Interactive.** Use this for exploration, paths no proof covers, and parity captures. After `launch`, drive with the Claude Code iOS Simulator `control` tool and pass `device: <udid>` on every call. Its default target is the first booted simulator, which can be the operator's own. `screenshot` returns an image 924 pixels wide, and `tap` takes device points, so multiply a position in that image by 0.422. `text` types into the focused field. The simulator uses the Mac keyboard as a hardware keyboard, so no on-screen keyboard appears. Without that tool there is no tap path outside XCUITest, so write a proof.

| Screen | Handles |
| --- | --- |
| Notice | `notice.continue` |
| Record store unavailable | `launch.storageUnavailable` with `Conversation history is temporarily unavailable.` and `Quit and reopen Enduragent.` |
| Connect | `connect.apiKey`, `connect.connect`, `connect.skip`, `connect.error`, `connect.athleteName`, `connect.fitness`, `connect.fatigue`, `connect.form`, `connect.continue` |
| Starter | `starter.progress`, `starter.credits`, `starter.start` |
| AI-provider consent | `consent.body`, `consent.accept`, `consent.decline`, `consent.error` after a failed consent write, and `consent.resume` after Not now |
| Chat | `chat.history` labeled with `archive.history`, `chat.settings` labeled with `settings.title`, `chat.newConversation`, the compose icon labeled `New conversation`, `chat.welcome`, `chat.newConversation.notice`, `chat.composer`, `chat.send`, `chat.stop`, `chat.composer.notSent`, `chat.composer.notice` for a coach-wide notice such as a locked Keychain, `chat.working`, `chat.turn.notice`, `chat.turn.tryAgain`, `chat.turn.buyCredits`, `chat.turn.restorePurchases`, `chat.turn.chooseAccessMethod`, `chat.turn.signInAgain`, `chat.turn.receivedBeforeClose`, `chat.turn.finishedWhileLocked`, `chat.note` for a durable review outcome, `chat.review.notice` for a review action result, `chat.slash.<command>`, `chat.transcript` for the List, `chat.composer.container` for the whole composer; `ReviewCardComposerProof` checks row separation and hittable Send with the keyboard open |
| Chat turn probe | Debug builds expose the invisible `chat.turnProgress` element with accessibility value `turns <count> settled <settled count>`. `TutorialHarness.exchange` reads it before sending and waits for one more turn with every turn settled. |
| Language sheet | `language.choice.<automatic or tag>` with the selected trait on the current choice, `language.close`, `language.saveFailed` |
| Records | `debug.records` in Debug, `records.list`, `records.device` at the top, `records.entries` after the counts, `records.count.<kind>`, `records.row.<id>` whose label names a `turnSettled` row's outcome such as `interrupted processEnded` or a `turnClaim` row's lease kind, `continuedProcessing` or `gracePeriodOnly`, and ends with the row's training account, `unconnected` or `intervals:<connection id>:<athlete id>`, and the toolbar `Refresh` button identified by `records.refresh` |
| Leases | `debug.leases` in Debug, `leases.row.<n>` whose label reads like `athlete continuedProcessing settledTurns 1 of 1 step 1 of 10 finished with notice`, and the `Refresh` button with no identifier |
| Workout preview | `chat.preview.cancel`, `chat.preview.add` inside the `Workout review` group, disabled until presentation is acknowledged; `chat.preview.notice` replaces both controls when the training account changes or Chat restores an unexpired v1 workout review, both connected to intervals.icu and disconnected |
| Settings | `settings.credits` under Model access, `settings.debug` in Debug builds only; Back from Model access Credits returns here |
| Credits | `credits.balance`, `credits.pack.<product id>`, `credits.note`, `credits.notice`; Back returns to the entry point, Settings or the conversation notice |
| Credentials | `debug.credentials` in Debug, `credentials.outcome`, `credentials.athlete`, `credentials.connection`, `credentials.keySuffix`, `credentials.lock`, `credentials.failNextWrite`, `credentials.apiKey`, `credentials.replace`, `credentials.replaceBlank`, `credentials.cancel`, `credentials.switchAthlete`, `credentials.disconnect` |
| History | `history.row.<boundary or chat id>`, then `archive.readOnly` in the pushed conversation |
| Debug | `fixture.requestCount`, `fixture.modelRequestCount`, `fixture.historyHead` (the first line of the history the last reply was sent with), `fixture.replyLanguage` (the first line of the reply-language section the last reply was sent with), `debug.language`, `debug.session`, `fixture.failNextAppend`, `fixture.expire` |
| Session (Debug) | `session.<field>.stored`, `session.<field>.input`, `session.<field>.save`, `session.<field>.outcome`, where `<field>` is `historyBudgetRatio` or `contextWindowOverride` |

The fixture athlete is Ada Kovač, athlete `i1001`. The key `other-athlete` resolves to Bo Lind, athlete `i2002`; every other non-empty key resolves to Ada. The fixture keychain starts with a Credits key and no intervals.icu connection, so the chat is unconnected until the connect step or Debug, Credentials stores a key. The fixed day is 1998-06-15. The connect screen shows `Fitness 42`, `Fatigue 49`, and `Form -7`. The starter grant and the balance are 200 credits. The packs are 500 and 2000 credits with purchases disabled. `FirstWeekFixture.script(for:)` picks the coach reply from the message text. `/review` gets the Saturday group ride summary. Text starting with `Remember that` gets `Noted. I'll remember you ride with a group on Saturdays.` Text containing `endurance ride` gets a workout preview. Anything else gets the week summary.

A message that starts with `fixture:` is a directive to the fakes, typed into `chat.composer` like any message. `FakeModelTransport` selects `FirstWeekFixture.respond(to:retry:)` for each attempt when its request executes:

| Message | Effect |
| --- | --- |
| `fixture:slow` | Waits 2 seconds, then streams the week summary one word every 250 ms, so `chat.working` shows for 2 seconds and the growing reply for about eight more. |
| `fixture:slow-flush` | The reply to this message and the next memory save each wait 6 seconds before answering, until another chat request executes. `New conversation` right after it shows `chat.working` under the old conversation for about 6 seconds. |
| `fixture:hang` | The model never answers. The 30 second watchdog fires, the coach retries once, the watchdog fires again, and the turn fails with `coach.error.providerDown` after about 60 seconds. |
| `fixture:fail 500`, `fixture:fail 401`, `fixture:fail 402`, `fixture:fail 429 7`, `fixture:fail network`, `fixture:fail timeout`, `fixture:fail overflow`, `fixture:fail finish` | The next model request fails before any reply text with the HTTP status, connection error, or stream end the directive names, parsed by the same rules as the real transport. `429 7` carries a `retry-after` of 7 seconds; `finish` is an unknown finish reason. A trailing `xN`, as in `fixture:fail 429 7 x4`, fails the next N requests. The coach retries retryable failures with real waits, so the notice needs `x3` for `500` and `network`, `x2` for `timeout`, and `x4` for `429` and `overflow`. |
| `fixture:memory-then-fail` | The model saves a `schedule` memory section, then the next request fails with a 500. The turn ends with a notice and no `Try again`, because information was saved. |
| `fixture:memory-then-hang` | The model saves a `schedule` memory section, then the next request never answers. Tapping Stop settles the turn with `This reply stopped before it finished. Some information was saved first.` and no `Try again`; left alone, the watchdog ends it after 30 seconds with the saved-work notice. Killing the app instead reopens it with the same sentence and Records lists `turnSettled` as `interrupted processEnded`. |
| `fixture:text-then-hang` | The model streams `This week has Tuesday sweet spot` and then stops answering. Records lists `replyObserved 1` while the text is on screen. After 30 seconds the watchdog ends the turn with `coach.error.providerDown` and no retry, because reply text was already shown. Killing the app while the text shows reopens the turn with `This reply stopped before it finished. Nothing was changed.` and `Try again`, no reply text, and no model request. |
| `fixture:teach` | The model saves a `schedule` memory section, then replies `Noted. I'll remember you ride with a group on Saturdays.` |
| `fixture:long` | The reply is the week summary written out for 100 days, about 5,200 tokens, so a few messages reach the soft flush gate and the trim. |
| `fixture:flush-partial` | Replies with the week summary and arms the next memory flush to save a `schedule` section and a `ledgerEvent`, then fail, so its job stays pending until the next launch. `fixture:fail overflow` right after it triggers that flush inside the overflow turn. |

Every directive keeps `fixture.requestCount` at `0 requests`. Queued messages keep separate scripts and delays. An unknown directive, such as `fixture:fail bogus`, gets an assistant reply saying `Unknown fixture directive: <message>`.

Debug has two fault controls. `fixture.failNextAppend` arms the next record append failure; send a message afterward to check that its draft survives acceptance failure. `fixture.expire` expires open leases without sending a message. Running turns settle as interrupted with `systemExpired`; queued turns settle as stopped before start. Model overrides are absent from Debug session settings, and older synced model IDs are ignored.

## UI test run

```sh
.claude/skills/verify-ios/helpers/sim.mjs test <run id> FirstConversationProof
```

Pass one or more proof classes, or `Class/testMethod`. The helper runs `test-without-building` against the products of `sim.mjs build`, so several test runs share one build. After a source change, run `build` and `install` first. The doctor flags a stale build. The command is:

```sh
xcodebuild test-without-building -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -destination id=<udid> -derivedDataPath DerivedData -parallel-testing-enabled NO -resultBundlePath <evidence>/uitest-<stamp>.xcresult -only-testing:EnduragentUITests/FirstConversationProof
```

The helper first terminates a running copy of the app, because XCUITest cannot terminate an app that `sim.mjs launch` started and the proof would fail with `Failed to terminate icu.enduragent.app`. `-parallel-testing-enabled NO` stops xcodebuild from cloning the simulator, because a clone would escape cleanup. The result bundle lands at `~/Library/Logs/enduragent-verify/<run id>/uitest-<stamp>.xcresult`. Beside it the helper writes the xcodebuild log `uitest-<stamp>.log`, the summary `uitest-<stamp>-summary.json`, and the exported screenshots in `uitest-<stamp>-attachments/` with `manifest.json`. It prints `Passed` or `Failed` with counts, then one `attachment <test> <name> <path>` line per screenshot, where `<name>` is the name the proof gave `TutorialHarness.attach`. On an xcodebuild failure it prints the tail of the log and exits 1. Failed, skipped, or missing test results also exit 1, even when xcodebuild exits 0. It saves the result tree as `uitest-<stamp>-tests.json` and the per-class counts as `uitest-<stamp>-classes.json`. On 2026-09-25 all eleven proofs passed, `FirstConversationProof` alone in 82 seconds and the other ten together in 4 minutes 20 seconds.

To prove state across a kill and reopen, call `TutorialHarness.relaunchKeepingStore(app)` inside one proof. It terminates the app, asserts `.notRunning`, swaps `fresh` for `keep` in the launch arguments, launches, and waits for `.runningForeground`. `RelaunchKeepsChatProof` is the model: onboard, send the week question, relaunch, then assert the question and the reply are back and the notice is not. Assert the screen and content the athlete sees, never only that the app came back. `XCUIDevice.shared.press(.home)` followed by `app.activate()` backgrounds and resumes the app without a kill. The interactive equivalent is `sim.mjs launch <run id> --keep`; without `--keep` the launch wipes the fixture store and opens on the notice.

**Every proof split across owned simulators.** One command builds once, discovers every UI proof class, splits them across two simulators, and deletes both after the run:

```sh
caffeinate -i env ENDURAGENT_VERIFY_RUNS=/Users/yerzhansagyt/Library/Logs/enduragent-m2/VSKILL/simulator-proof node .claude/skills/verify-ios/helpers/sim.mjs suite --build-folder /tmp/enduragent-dd/VSKILL --shards 2
```

Change `--shards` to choose N simulators. Append class names to run a subset, for example `suite --shards 2 FirstConversationProof ConfirmedPreviewDarkProof`. A suite takes classes, not individual methods. Each shard runs light proofs first and `DarkProof` classes second, with `-parallel-testing-enabled NO` on every xcodebuild call. Its `finally` cleanup also runs after a failed proof or boot. The coordinator waits for every shard and checks cleanup again before reporting.

Each shard has its own `<suite id>-shard-N/` folder with `run.json`, xcodebuild logs, result bundles, exported attachments, and `summary.json`. The `<suite id>/` folder holds `plan.json`, each worker's log, a combined `summary.json`, a per-class table in `summary.md`, and `timings.json`. Counts include passed, failed, skipped, and missing results. Any failed shard, failed test, skipped test, or missing class makes the command exit 1. An infrastructure failure before testing can leave a shard without a result bundle; its summary still names every unverified class.

Without timings, the planner distributes classes evenly. If `<evidence root>/timings.json` exists, or you pass `--timings <file>`, it assigns the longest measured classes first to the least-loaded shard. The file is a JSON map from class names to positive seconds, for example `{"FirstConversationProof": 82}`. New classes use the mean of known durations. A completed suite writes an updated timing file into its own folder; pass that file to the next run to reuse measurements. An explicitly requested missing or malformed timing file fails before simulator creation.

Discovery takes classes whose names end in `Proof`. Classes that end in `Probe` measure time and run on their own. `LaunchLatencyProbe` must run `testSeedTwoHundredTurns` before its launch tests, and XCTest runs a class's tests in name order, so in one run the launch tests find no seeded store.

The history and legacy-review upgrade proofs use committed v1 stores and must pass with zero skips. Each proof copies a fresh store set before launch, so data left by another proof does not supply its upgrade precondition. A missing fixture resource is a failure.

**Upgrade proofs.** Build the current checkout and run both proofs together:

```sh
.claude/skills/verify-ios/helpers/sim.mjs build
.claude/skills/verify-ios/helpers/sim.mjs test <run id> UpgradeHistoryProof LegacyReviewNoticeProof
```

Require `2 passed, 0 failed, 0 skipped`. `TutorialHarness.launchUpgrade` uses `FixtureArguments` with `.v1History` or `.v1Review` and completed onboarding, then accepts AI-provider consent. Debug fixture preparation copies the corresponding synced and local databases from `apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures/v1-upgrade` into the app's fixture directory before the store opens.

`UpgradeHistoryProof` opens the history fixture on the welcome and asserts two archived conversations labeled `Earlier chat`. It opens an archive and checks the saved question and reply, the read-only notice, and the absence of composer controls.

`LegacyReviewNoticeProof` opens the review fixture with one pending workout review in `main`. It reads the earlier-version notice while disconnected from intervals.icu, connects the fixture athlete through Debug, Credentials, and reads the notice again. It relaunches in German and checks the localized notice. Approval and cancel controls stay absent, and Records retains `pendingProposal 1` without `proposalCleared` or `reviewApplied`. The fixture clock stays at `1998-06-15T08:00:00Z`, within the review's ten-minute lifetime. The committed fixture covers a create review. Package migration tests cover v1 edit and deletion reviews.

The stores were generated through the frozen v1 code at `82254bbda75ba79b0156d7efd3deac223489b2b0`. To regenerate them on macOS with that code's compatible Swift toolchain, run:

```sh
caffeinate -i node tools/generate-v1-upgrade-stores.mjs
```

The generator archives the frozen package and its unchanged `FirstWeekFixture` into a temporary directory, adds `tools/fixtures/V1UpgradeStoreSeed.swift` to the test target, and drives the v1 `Coach.send` and `SwiftDataRecordLog`. It checkpoints the generated SQLite databases and copies them into the two committed fixture folders. Do not hand-edit database rows or the frozen schema. CI and UI proof runs consume the committed stores and need no v1 installation or detached worktree.

## Verify on the real phone

This is the saved procedure for the 2026-10-01 run on build `2bbe2ee`. The phone runner lives in `apps/ios/EnduragentPhoneTests/PhoneRun.swift`. Only the `EnduragentPhone` scheme includes that target. The Swift file also compiles out on simulators. The normal `Enduragent` scheme and `sim.mjs` never execute it, and it uses no `XCTSkip`.

Before **every** invocation, ask the operator for that invocation's message budget. Explain that live Send and Try again actions spend Credits or use the connected OpenRouter account. Each Send or Try again consumes one budget slot. The full procedure needs seven Sends and two Try again taps, so its minimum is nine slots. New conversation can also save memory through the model. Do not infer a new budget from a previous run. If a run fails or stops, report the actions already taken and ask for a new budget before another invocation.

Ask the operator to provide the connected, unlocked iPhone and approve the single calendar Add for this run. Never enter a passcode, password, API key, or any other credential. Never accept a consent, terms, or login screen. Never tap purchases, sign out, disconnect intervals.icu, delete the app, or erase its data. Never send or tap Try again beyond the approved budget. The runner refuses a missing budget before launch, checks the budget before every message action, and permits one Add only.

1. Build and install in place with the command below. The device identifier is an argument supplied for this run, never a committed value. Keep build products under `/tmp` and logs and result bundles outside the tree.
2. Launch plainly, with no fixture arguments and no launch environment. Capture the first screen. If the phone is locked or shows consent, terms, login, onboarding, or any system alert, stop without tapping it. The operator handles the screen. The runner fails with `PhoneRunBlocked`, preserves its attachments, and sends no message. Ask for a fresh budget before restarting.
3. On the conversation screen, check the earlier conversation, open History and a read-only archived conversation, and record Credits before the run.
4. Send `What should I focus on in training this week?`. Capture partial text while working and the settled reply.
5. Send the eight-week base-training question in the script. Stop during partial text, check the dimmed partial reply, notice, and Try again, then tap Try again once. A missed Stop is a failed proof. Do not resend without another budget.
6. Send the short tempo-ride question, press Home for twenty seconds, and return. Check the complete reply and the finished-while-locked line. The 2026-10-01 run pressed Home; it did not lock the phone. An actual lock and unlock is an operator action.
7. Send the 100 km pacing question, terminate during partial text, and relaunch plainly. Check the interrupted turn and Try again, then tap Try again once. Partial text lost on a hard kill is accepted for Milestone 2 under G16.
8. Request one 45-minute endurance ride for tomorrow. Capture the review and tap Add exactly once. Capture the Done line. The operator checks intervals.icu for exactly one matching event on that date. The UI's Done line alone cannot prove the server count. Do not repeat Add if its outcome is uncertain.
9. Request one recovery spin for the day after tomorrow. Cancel once and relaunch. Check that the review stays gone.
10. Start New conversation with the compose icon in the top bar, check the composer, send the warm-up question, and open the previous conversation in History. Record Credits afterward and leave the app in the foreground. The 2026-10-01 run did not exercise a second device or purchases.

Run only after the operator has answered the budget question. Supply `DEVICE_ID`, `MESSAGE_BUDGET`, and a new `PHONE_RUN` evidence folder in the shell:

```sh
xcodegen generate --spec apps/ios/project.yml
caffeinate -i xcodebuild test -project apps/ios/Enduragent.xcodeproj -scheme EnduragentPhone -configuration Debug -sdk iphoneos -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath /tmp/enduragent-dd/VSKILL-phone -parallel-testing-enabled NO -resultBundlePath "$PHONE_RUN/phone.xcresult" -only-testing:EnduragentPhoneTests/PhoneRun ENDURAGENT_PHONE_MESSAGE_BUDGET="$MESSAGE_BUDGET" > "$PHONE_RUN/phone.log" 2>&1
```

The runner checks English questions exactly and requires existing conversation and History data, matching the original upgrade run. The operator selects the language and handles any preconditions on the phone. Export attachments from the result bundle and inspect the screenshots. Report messages, Try again taps, Add taps, Credits before and after, the calendar event, any failed step, and the state left on the phone. Attachments can contain private conversations or the Home screen; keep them in the operator's local evidence folder.

## States fixture hooks cannot reach

These gaps were checked against `FixtureArguments`, `FirstWeekFixture`, Debug controls, and the Milestone 1 close-out backlog. A package result proves its contract, not pixels. Do not claim a missing screen proof as passed.

| State without a UI hook | Evidence to use instead |
| --- | --- |
| A calendar write loses its response in the running session | `SingleProposalReviewsTests.lostResponseSettlesUncertain` proves the current package outcome through `Coach.decide`. Pending unknown-write recovery and read-back need the 0.4b hooks and proofs before their screens can be called verified. |
| A lost-response write is found on a later calendar read, or a calendar network read fails | The P51 report records `DurableCalendarWriteTests.committedWriteWithLostResponseIsConfirmedByReading(response:)` and `unreadableCalendarKeepsTheWriteUnknown(malformed:)` on PR #84. They are evidence for that pending change, not tests on this tree. Unit 0.4b supplies the UI hooks. A Keychain lock follows a different branch and cannot prove a network read failure. |
| A workout review's record refresh fails and later succeeds | `FirstTurnTests.failedReviewRefreshKeepsTheCardUntilASuccessfulRead` proves retention and recovery. Unit 0.4b supplies a record-read failure hook and proves disabled controls on screen. |
| Stop while the fixture turn is still proposing its workout | `RetryLadderTests.approvalDuringBackoffSettlesSavedWork`, `RetryLadderTests.approvalBeforeTimeoutFailureSettlesSavedWork`, and `RetryLadderTests.hungApprovalDoesNotBlockStopOrNewSend` cover the package boundaries. The fixture proposing turn finishes at once; Stop during `fixture:slow` does not prove this state. |
| Real continued-processing banners, OS suspension or expiry, lock and unlock, and a hard kill losing partial text | The real-phone procedure and its screenshots. Home proves backgrounding only. The operator performs an actual lock and unlock. Fixture host expiry proves the package's expiry response, not when iOS expires a real lease. A device run must capture an actual OS expiry before claiming that part. |
| Live networking, real Keychain access or sync, CloudKit imports, and a second device's consent or conversation | The closing real-phone run plus an operator-assisted second-device check on the same Apple ID. The one-phone script does not cover the second device. Fixture stores have CloudKit off. |
| Exactly one intervals.icu event, including UID upsert after an uncertain write | The operator reads the real calendar after the single Add. Repeated-write UID-upsert evidence belongs to unit 0.4's authorized live check; this phone script never repeats Add. |
| StoreKit prices, purchases, and Restore | Operator-approved store-release testing. G12 excludes purchases and Restore from Milestone 2, so neither this suite nor the phone script claims that proof. |

## Compare with the prototype

The approved prototypes are HTML. Their native-look captures are 390 × 844 PNGs named `native-<prototype>-<state>-<theme>.png` in `~/projects/enduragent/desktop/docs/prototypes/ios/captures-2026-09-25/`. Set `ENDURAGENT_PROTOTYPE_CAPTURES` to use another folder. Parity is by state and copy, not pixels, because SwiftUI system rendering differs from the HTML. Do not add a pixel-diff tool.

1. Drive the app to the state with the interactive harness.
2. Run `sim.mjs parity <run id> <prototype>-<state> <light|dark>`, for example `parity <run id> chat-menu dark`. The helper sets the simulator appearance, waits 1.5 seconds, and writes `parity/<prototype>-<state>-<theme>/` with `prototype.png`, `simulator.png` at 1170 × 2532, and `simulator-390.png` at the prototype's 390 × 844. An unknown state prints every available state. The appearance stays set afterwards.
3. To use a proof screenshot instead, add `--from <attachment png>`. For the dark theme, name the proof class with the `DarkProof` suffix. `sim.mjs test` runs those classes in a second `xcodebuild` call after `xcrun simctl ui <udid> appearance dark`, then sets the appearance back to `light`, so one `test` call can mix light and dark proofs. Neither the `-AppleInterfaceStyle Dark` launch argument nor `XCUIDevice.shared.appearance` changes the app on the iOS 26 simulator; a poll of `simctl ui appearance` read `light` through a whole proof that set it on 2026-09-27.
4. Read `prototype.png` and `simulator-390.png` together and check each item:
   - The same states exist, and the athlete can reach each one.
   - The same catalog copy appears word for word. Copy comes from `packages/i18n/catalogs/en.json` through `phrasebook.say`.
   - The controls appear in the same order, for example `Cancel` before the confirming control.
   - The same enable rules hold. A control disabled in a prototype state is disabled in the same app state.
5. Report each item as a pass or as the exact mismatch, with both image paths.

| Prototype state | App state today |
| --- | --- |
| `chat-welcome` | Chat right after onboarding: `chat.welcome` lists the supported commands whether or not intervals.icu is connected |
| `chat-menu`, `chat-menu-nosync` | The slash list after typing `/` in `chat.composer`. The nosync state is the same list after `Skip for now`. |
| `chat-new-conversation` | A reply with `chat.newConversation` in the top bar; after the tap, the welcome with `New conversation started.` |
| `review-ready` | The `Workout review` card after a workout request |
| `review-canceled-first` | The chat after `chat.preview.cancel` |
| `chat-working` | Within one second of sending `fixture:slow`: `chat.working` reads `Coach is working…` and no reply text yet |
| `chat-streaming` | About three seconds after sending `fixture:slow`: part of the week summary with the working row still under it |
| `chat-failed` | After `fixture:fail network x3`: `chat.turn.notice` under the message reads `The model provider is having trouble — try again in a few minutes.` with `Try again` in `chat.turn.tryAgain` |
| `interruption-accepted` | After `sim.mjs launch <run id> -EnduragentFixtureCoalescing 60000`, onboarding, `fixture:hang`, and `sim.mjs launch <run id> --keep` before the minute ends: the message once with `Received before the app closed. Tap Try again to send it.` and `Try again`. `AcceptSurvivesKillProof` attachment `accept-kill-reopen` shows it |
| `interruption-draft` | After tapping `fixture.failNextAppend` in Debug and sending a message: the composer keeps the text with `Not sent. Your draft is still here.` under it. `StorageFaultProof` attachment `storage-fault-not-sent` shows it |
| `interruption-completed` | A reply that landed while the app was in the background: the whole reply with `Finished while the phone was locked.` under it, after `FinishedWhileAwayProof` |
| `interruption-interrupted` | The dimmed partial reply with `This reply stopped before it finished. Nothing was changed.` and `Try again`, after `StopProof` or `ExpiryProof` |
| `chat-long`, `chat-play`, other `review-*`, `language-*`, `settings-*`, other `interruption-*` | No app screen yet |

## Evidence

Each run writes to `~/Library/Logs/enduragent-verify/<run id>/`. Set `ENDURAGENT_VERIFY_RUNS` to move the root. The folder is outside the repository, so no screenshot or result bundle can be committed, and it survives cleanup and worktree removal. It holds:

- `run.json` with the run id, simulator name, udid, device type, runtime, checkout, revision, build folder, and source digest; git checkouts use `git describe --always --dirty`, and exports use `ENDURAGENT_VERIFY_REVISION` or `exported-tree`;
- `<label>.png` from `sim.mjs shot <run id> <label>`;
- the UI test files described in **UI test run**;
- `parity/<prototype>-<state>-<theme>/` from `sim.mjs parity`.

The helper uses unique run and result names. Cleanup keeps the evidence. The suite coordinator finalizes each shard summary after checking the worker exit status. Never copy evidence into the repository.

Proof standards:

- Drive the athlete's path by tapping controls from launch onward. Setting `ShellModel` state, calling model methods, and unit tests are not UI proof.
- Capture the action and the resulting state. Take a `shot` before the tap and after the result, or use a proof whose attachment shows the end state.
- Check the side effect beside the pixels. Settings, then Debug, must show `fixture.requestCount` reading `0 requests`. `TutorialHarness.assertZeroFixtureRequests` asserts it. Any other count means a code path escaped the fakes, which is a finding.
- The fixture is the only mock, and it replaces services at the same seam as production, `AppServices`. Fixture mode blocks all `URLSession` traffic, keeps records in a SwiftData store under `Application Support/fixture/` with CloudKit off, writes keys through `ICloudKeychainStore` with a file-backed `FixtureSecretStoreBacking`, and skips the StoreKit price lookup. A fixture run cannot prove live networking, the real keychain, iCloud sync, or StoreKit prices. Say so when a change touches them.
- Report the feature ID and the entry point with every artifact. Do not report a skipped entry point as verified through another one.

## Cleanup

Run `sim.mjs cleanup <run id>` when the run ends, and after every failed attempt before the next one. It shuts down and deletes `enduragent-verify-<run id>`, which removes the installed app and its data. It confirms the simulator is gone and lists the evidence it kept. Running it twice is safe.

Never run `simctl delete all`, `simctl shutdown all`, or `simctl erase`. Never quit Simulator.app or kill CoreSimulatorService, and never kill a process by name. The operator keeps their own simulators booted, and a parallel run owns its own. The selected build folder is a build cache, not evidence.

## Helpers

`helpers/sim.mjs` is a dependency-free Node script. Every command prints what it did and exits non-zero on failure.

| Command | Does |
| --- | --- |
| `doctor [<run id>]` | Read-only readiness check described in **Doctor** |
| `build` | XcodeGen, then `build-for-testing` into the selected build folder |
| `create <kebab-slug>` | New run id, evidence folder, and booted simulator |
| `install <run id>` | Installs the built app on the run's simulator |
| `launch <run id> [--keep] [app arguments]` | Kills and opens the app in fixture mode; `--keep` reuses the fixture state instead of wiping it |
| `shot <run id> <kebab-label>` | Screenshot to `<evidence>/<label>.png` |
| `test <run id> <proof>...` | UI proofs on the run's simulator, with attachments exported; `DarkProof` classes run in dark appearance |
| `suite [<proof class>...] --shards <N> [--timings <json>]` | Build once, run owned simulator shards, clean up, and combine per-class results |
| `parity <run id> <prototype>-<state> <light\|dark> [--from <png>]` | Prototype capture beside a simulator screenshot |
| `cleanup <run id>` | Deletes the run's simulator and keeps the evidence |

Run the helper tests with `node --test tools/verify-ios.test.mjs`. They also run in `pnpm check:source`. The command tests use fake executables and never touch a simulator.

`ENDURAGENT_SIM_DEVICE` changes the device type. Parity comparisons assume the default iPhone 17e.

Keep the feature map honest as the app changes with `/maintain-verification-skill`.
