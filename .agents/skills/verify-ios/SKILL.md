---
name: verify-ios
description: Drive the Enduragent iPhone app, the SwiftUI app in apps/ios, on a dedicated iOS 26 simulator in fixture mode the way an athlete taps through it, and keep screenshots, xcresult bundles, and the fixture request count as proof. Use to prove an iOS UI change, reproduce a phone bug on the simulator, run the XCUITest proofs on an isolated simulator, or compare a screen with the approved native prototypes.
---

# Verify the Enduragent iPhone app

The surface is the iPhone app built from `apps/ios/project.yml`. Every simulator verification run creates its own simulator, `enduragent-verify-<run id>`, from the newest iOS 26 runtime. The default device is iPhone 17e, which is 390 × 844 points, the same viewport as the prototype captures. Never drive a simulator the run did not create. Physical-device verification uses only the separate real-phone procedure below.

Simulator proofs run in fixture mode, `-EnduragentFixture first-week`. `AppServices.fixture` swaps intervals.icu, credits, the model transport, the keychain, and the record store for fakes. The fakes keep their state on disk under the app's `Application Support/fixture/` and in the `UserDefaults` suite `icu.enduragent.fixture`, so a relaunch can either wipe it (`-EnduragentFixtureStore fresh`, the default) or reuse it (`-EnduragentFixtureStore keep`). `FixtureBlockingURLProtocol` fails and counts every `URLSession` request. No API key, account, or network is needed.

Every simulator step goes through one helper. Run it by path from the checkout you are verifying. It resolves the source tree from its own location, without git, so an exported tree and a shell started elsewhere both work. Source manifests walk `apps/ios` and omit generated projects and build caches. An export needs no symlink or temporary git repository. Set `ENDURAGENT_VERIFY_REVISION` to the exported commit SHA to record its provenance. Without it, `run.json` says `exported-tree` and records a source digest.

```sh
.agents/skills/verify-ios/helpers/sim.mjs build
.agents/skills/verify-ios/helpers/sim.mjs create onboarding
.agents/skills/verify-ios/helpers/sim.mjs doctor <run id>
.agents/skills/verify-ios/helpers/sim.mjs install <run id>
.agents/skills/verify-ios/helpers/sim.mjs test <run id> FirstConversationProof
.agents/skills/verify-ios/helpers/sim.mjs cleanup <run id>
```

Every command accepts `--build-folder <path>`. The flag overrides `ENDURAGENT_VERIFY_BUILD`; both default to `<tree>/DerivedData`. Use the same folder for build, doctor, install, and test. Milestone 2 builds go under `/tmp/enduragent-dd/`, for example `ENDURAGENT_VERIFY_BUILD=/tmp/enduragent-dd/VSKILL`.

Below, `sim.mjs` means `.agents/skills/verify-ios/helpers/sim.mjs`. `create` prints the run id, for example `2026-10-01-120000-a1b2c3d4-onboarding`. Commands for that simulator take its run id.

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
| Connect | `connect.apiKey`, `connect.connect`, `connect.skip`, `connect.saved`, `connect.notice`, `connect.displayAction`, `connect.athleteName`, `connect.athleteID`, `connect.fitness`, `connect.fatigue`, `connect.form`, `connect.continue` |
| Starter | `starter.progress`, `starter.credits`, `starter.start` |
| AI-provider consent | `consent.body`, `consent.accept`, `consent.decline`, `consent.error` after a failed consent write, and `consent.resume` after Not now |
| Chat | `chat.history` labeled with `archive.history`, `chat.settings` labeled with `settings.title`, `chat.newConversation`, the compose icon labeled `New conversation`, `chat.welcome`, `chat.newConversation.notice`, `chat.composer`, `chat.send`, `chat.stop`, `chat.composer.notSent`, `chat.composer.notice` for a coach-wide notice such as a locked Keychain, `chat.working`, `chat.turn.notice`, `chat.turn.tryAgain`, `chat.turn.buyCredits`, `chat.turn.restorePurchases`, `chat.turn.chooseAccessMethod`, `chat.turn.signInAgain`, `chat.turn.receivedBeforeClose`, `chat.turn.finishedWhileLocked`, `chat.note` for a durable review outcome, `chat.review.notice` for a review action result, `chat.review.connect` for missing training connection guidance, `chat.slash.<command>`, `chat.transcript` for the List, `chat.composer.container` for the whole composer; `ReviewCardComposerProof` checks row separation and hittable Send with the keyboard open |
| Chat turn probe | Debug builds expose the invisible `chat.turnProgress` element with accessibility value `turns <count> settled <settled count>`. `TutorialHarness.exchange` reads it before sending and waits for one more turn with every turn settled. |
| Language sheet | `language.choice.<automatic or tag>` with the selected trait on the current choice, `language.close`, `language.saveFailed` |
| Settings language | `settings.language` opens the same sheet as `/language`, showing the saved preference in the row |
| Records | `debug.records` in Debug, `records.list`, `records.device` at the top, `records.entries` after the counts, `records.count.<kind>`, `records.row.<id>` whose label names a `turnSettled` row's outcome such as `interrupted processEnded` or a `turnClaim` row's lease kind, `continuedProcessing` or `gracePeriodOnly`, and ends with the row's training account, `unconnected` or `intervals:<connection id>:<athlete id>`, and the toolbar `Refresh` button identified by `records.refresh` |
| Leases | `debug.leases` in Debug, `leases.row.<n>` whose label reads like `athlete continuedProcessing settledTurns 1 of 1 step 1 of 10 finished with notice`, and the `Refresh` button with no identifier |
| Workout preview | `chat.preview.cancel`, `chat.preview.add` inside the `Workout review` group, disabled until presentation is acknowledged; `chat.preview.notice` replaces both controls when the training account changes or Chat restores an unexpired v1 workout review, both connected to intervals.icu and disconnected |
| Settings | `settings.credits` under Model access, `settings.training` under Training connection, `settings.debug` in Debug builds only; Back from Model access Credits returns here |
| Credits | `credits.balance`, `credits.pack.<product id>`, `credits.note`, `credits.notice`; Back returns to the entry point, Settings or the conversation notice |
| Training connection | `settings.training`, `training.edit`, `training.apiKey`, `training.save`, `training.keep`, `training.cancel`, `training.disconnect`, `training.saved`, `training.notice`, `training.athlete`, `training.athleteID`, `training.fitness`, `training.fatigue`, `training.form`, `training.displayAction`; owner and disconnect confirmation alerts. Fixture-only Debug handles are `fixture.connection`, `fixture.failCredentialWrite`, `fixture.toggleKeychainLock`. |
| History | `history.row.<boundary or chat id>`, then `archive.readOnly` in the pushed conversation |
| Debug | `fixture.requestCount`, `fixture.modelRequestCount`, `fixture.historyHead` (the first line of the history the last reply was sent with), `fixture.replyLanguage` (the first line of the reply-language section the last reply was sent with), `debug.language`, `debug.session`, `fixture.failNextAppend`, `fixture.expire` |
| Session (Debug) | `session.<field>.stored`, `session.<field>.input`, `session.<field>.save`, `session.<field>.outcome`, where `<field>` is `historyBudgetRatio` or `contextWindowOverride` |

The fixture athlete is Ada Kovač, athlete `i1001`. The key `other-athlete` resolves to Bo Lind, athlete `i2002`. The peer hook also supplies rejected and unavailable keys. Other non-empty keys resolve to Ada. The fixture keychain starts with a Credits key and no intervals.icu connection, so the chat is unconnected until the connect step or Debug, Credentials stores a key. The fixed day is 1998-06-15. The connect screen shows `Fitness 42`, `Fatigue 49`, and `Form -7`. The starter grant and the balance are 200 credits. The packs are 500 and 2000 credits with purchases disabled. `FirstWeekFixture.script(for:)` picks the coach reply from the message text. `/review` gets the Saturday group ride summary. Text starting with `Remember that` gets `Noted. I'll remember you ride with a group on Saturdays.` Text containing `endurance ride` gets a workout preview. Anything else gets the week summary.

A message that starts with `fixture:` is a directive to the fakes, typed into `chat.composer` like any message. `FakeModelTransport` selects `FirstWeekFixture.respond(to:retry:)` for each attempt when its request executes:

| Message | Effect |
| --- | --- |
| `fixture:slow` | Waits 2 seconds, then streams the week summary one word every 250 ms, so `chat.working` shows for 2 seconds and the growing reply for about eight more. |
| `fixture:slow-flush` | The reply to this message and the next memory save each wait 6 seconds before answering, until another chat request executes. `New conversation` right after it shows `chat.working` under the old conversation for about 6 seconds. |
| `fixture:hang` | The model never answers. The 30 second watchdog fires, the coach retries once, the watchdog fires again, and the turn fails with `coach.error.providerDown` after about 60 seconds. |
| `fixture:fail 500`, `fixture:fail 400`, `fixture:fail 401`, `fixture:fail 402`, `fixture:fail 429 7`, `fixture:fail network`, `fixture:fail timeout`, `fixture:fail overflow`, `fixture:fail finish` | The next model request fails before any reply text with the HTTP status, connection error, or stream end the directive names, parsed by the same rules as the real transport. `429 7` carries a `retry-after` of 7 seconds; `finish` is an unknown finish reason. A trailing `xN`, as in `fixture:fail 429 7 x4`, fails the next N requests. The coach retries retryable failures with real waits, so the notice needs `x3` for `500` and `network`, `x2` for `timeout`, and `x4` for `429` and `overflow`. |
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
.agents/skills/verify-ios/helpers/sim.mjs test <run id> FirstConversationProof
```

Pass one or more proof classes, or `Class/testMethod`. The helper runs `test-without-building` against the products of `sim.mjs build`, so several test runs share one build. After a source change, run `build` and `install` first. The doctor flags a stale build. The command is:

```sh
xcodebuild test-without-building -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -destination id=<udid> -derivedDataPath DerivedData -parallel-testing-enabled NO -resultBundlePath <evidence>/uitest-<stamp>.xcresult -only-testing:EnduragentUITests/FirstConversationProof
```

The helper first terminates a running copy of the app, because XCUITest cannot terminate an app that `sim.mjs launch` started and the proof would fail with `Failed to terminate icu.enduragent.app`. `-parallel-testing-enabled NO` stops xcodebuild from cloning the simulator, because a clone would escape cleanup. The result bundle lands at `~/Library/Logs/enduragent-verify/<run id>/uitest-<stamp>.xcresult`. Beside it the helper writes the xcodebuild log `uitest-<stamp>.log`, the summary `uitest-<stamp>-summary.json`, and the exported screenshots in `uitest-<stamp>-attachments/` with `manifest.json`. It prints `Passed` or `Failed` with counts, then one `attachment <test> <name> <path>` line per screenshot, where `<name>` is the name the proof gave `TutorialHarness.attach`. On an xcodebuild failure it prints the tail of the log and exits 1. Failed, skipped, or missing test results also exit 1, even when xcodebuild exits 0. It saves the result tree as `uitest-<stamp>-tests.json` and the per-class counts as `uitest-<stamp>-classes.json`. On 2026-09-25 all eleven proofs passed, `FirstConversationProof` alone in 82 seconds and the other ten together in 4 minutes 20 seconds.

To prove state across a kill and reopen, call `TutorialHarness.relaunchKeepingStore(app)` inside one proof. It terminates the app, asserts `.notRunning`, swaps `fresh` for `keep` in the launch arguments, launches, and waits for `.runningForeground`. `RelaunchKeepsChatProof` is the model: onboard, send the week question, relaunch, then assert the question and the reply are back and the notice is not. Assert the screen and content the athlete sees, never only that the app came back. `XCUIDevice.shared.press(.home)` followed by `app.activate()` backgrounds and resumes the app without a kill. The interactive equivalent is `sim.mjs launch <run id> --keep`; without `--keep` the launch wipes the fixture store and opens on the notice.

**Every proof split across owned simulators.** One command builds once, discovers every UI proof class, splits them across two simulators, and deletes both after the run:

```sh
caffeinate -i env ENDURAGENT_VERIFY_RUNS=/Users/yerzhansagyt/Library/Logs/enduragent-m2/VSKILL/simulator-proof node .agents/skills/verify-ios/helpers/sim.mjs suite --build-folder /tmp/enduragent-dd/VSKILL --shards 2
```

Change `--shards` to choose N simulators. Append class names to run a subset, for example `suite --shards 2 FirstConversationProof ConfirmedPreviewDarkProof`. A suite takes classes, not individual methods. Each shard runs light proofs first and `DarkProof` classes second, with `-parallel-testing-enabled NO` on every xcodebuild call. Its `finally` cleanup also runs after a failed proof or boot. The coordinator waits for every shard and checks cleanup again before reporting.

Each shard has its own `<suite id>-shard-N/` folder with `run.json`, xcodebuild logs, result bundles, exported attachments, and `summary.json`. The `<suite id>/` folder holds `plan.json`, each worker's log, a combined `summary.json`, a per-class table in `summary.md`, and `timings.json`. Counts include passed, failed, skipped, and missing results. Any failed shard, failed test, skipped test, or missing class makes the command exit 1. An infrastructure failure before testing can leave a shard without a result bundle; its summary still names every unverified class.

Without timings, the planner distributes classes evenly. If `<evidence root>/timings.json` exists, or you pass `--timings <file>`, it assigns the longest measured classes first to the least-loaded shard. The file is a JSON map from class names to positive seconds, for example `{"FirstConversationProof": 82}`. New classes use the mean of known durations. A completed suite writes an updated timing file into its own folder; pass that file to the next run to reuse measurements. An explicitly requested missing or malformed timing file fails before simulator creation.

Discovery takes classes whose names end in `Proof`. Classes that end in `Probe` measure time and run on their own. `LaunchLatencyProbe` must run `testSeedTwoHundredTurns` before its launch tests, and XCTest runs a class's tests in name order, so in one run the launch tests find no seeded store.

The history and legacy-review upgrade proofs use committed v1 stores and must pass with zero skips. Each proof copies a fresh store set before launch, so data left by another proof does not supply its upgrade precondition. A missing fixture resource is a failure.

**Upgrade proofs.** Build the current checkout and run both proofs together:

```sh
.agents/skills/verify-ios/helpers/sim.mjs build
.agents/skills/verify-ios/helpers/sim.mjs test <run id> UpgradeHistoryProof LegacyReviewNoticeProof
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

### Prove the OpenRouter HTTPS callback and cancellation

Unit U7-3 adds `EnduragentPhoneTests/OpenRouterSignInPhoneCheck`. Run it at slice completion after 7.2 supplies `OpenRouterSignInSession` from `AppServices` and the sign-in actions are connected. G34 leaves this proof pending while the operator is away. Controlled app completions do not prove the installed phone's associated-domain handoff. No simulator proof is owed while the domain is unconfigured.

The operator configures `enduragent.icu`, its site-association file, the App ID capability and the signed install's Associated Domains entitlement. The callback is `https://enduragent.icu/auth/openrouter/callback`. This unit changes no entitlement or signing setting. Use an unlocked physical iPhone, English, working model access, accepted consent, no draft, no unfinished turn and no open workout review.

Before each invocation, ask for its message budget. Explain that the callback test sends zero messages. The cancel test sends one live message through the previous access method and can spend Credits or use the connected OpenRouter account. Obtain explicit approval of that usage before the cancel test. Neither test taps Try again, New conversation, a purchase or a calendar Add. A stopped or failed invocation needs a fresh budget.

1. Run `testHTTPSCallbackSavesConnection` with a new local evidence folder and the approved budget, which may be zero. The test launches plainly, opens Settings, then Choose access method, and taps Sign in with OpenRouter once.
2. Handle the system permission alert by hand. The runner waits for the browser page and saves `openrouter-authorization-page`. At the OpenRouter page, automation stops all interaction. Confirm the host is `openrouter.ai` and the authorization identifies Enduragent before continuing. Never enter credentials through automation. The operator signs in and approves by hand within the runner's 180-second deadline.
3. Check `openrouter-callback-saved` and `openrouter-callback-reopened`. The system sheet must dismiss, OpenRouter account must stay selected after relaunch, and the conversation's turn progress must remain unchanged. Inspect the phone's earlier messages as well. Keep the callback criterion pending if the sheet remains open or the choice is not saved.
4. Prepare a working previous method with no pending consent. Obtain a new budget of at least one live Send, then run `testCancelKeepsPreviousAccessForNextTurn` in a different evidence folder. Run once with Credits selected and once with a working OpenRouter account, with a fresh budget for each invocation.
5. Handle the system permission alert by hand. Inspect `openrouter-cancel-page`, then cancel the system sheet by hand without approving a new connection. The runner enters no credential and taps nothing in the browser. It waits at most 180 seconds for dismissal.
6. Inspect `openrouter-before-cancel`, `openrouter-cancel-kept-access`, `openrouter-cancel-next-turn` and `openrouter-cancel-access-reopened`. The previous method must remain selected, the conversation must remain, and the single `What is an endurance ride?` message must receive a non-empty reply without a failure notice. Inspect the earlier messages and the reply. The phone remains in the conversation.

Supply the connected phone's identifier only at invocation time. Choose one test method below, set `OPENROUTER_PHONE_TEST`, obtain `MESSAGE_BUDGET`, and create a new `OPENROUTER_PHONE_RUN` folder. Do not commit identifiers, keys, authorization codes, screenshots or result bundles.

```sh
mkdir -p "$OPENROUTER_PHONE_RUN"
xcodegen generate --spec apps/ios/project.yml
caffeinate -i xcodebuild test -project apps/ios/Enduragent.xcodeproj -scheme EnduragentPhone -configuration Debug -sdk iphoneos -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath /tmp/enduragent-dd/U7-3 -parallel-testing-enabled NO -resultBundlePath "$OPENROUTER_PHONE_RUN/openrouter.xcresult" -only-testing:"EnduragentPhoneTests/OpenRouterSignInPhoneCheck/$OPENROUTER_PHONE_TEST" ENDURAGENT_PHONE_MESSAGE_BUDGET="$MESSAGE_BUDGET" > "$OPENROUTER_PHONE_RUN/phone.log" 2>&1
xcrun xcresulttool get test-results summary --path "$OPENROUTER_PHONE_RUN/openrouter.xcresult" > "$OPENROUTER_PHONE_RUN/summary.json"
xcrun xcresulttool export attachments --path "$OPENROUTER_PHONE_RUN/openrouter.xcresult" --output-path "$OPENROUTER_PHONE_RUN/attachments"
```

`OPENROUTER_PHONE_TEST` is either `testHTTPSCallbackSavesConnection` or `testCancelKeepsPreviousAccessForNextTurn`. Check that exactly that test passed without a skip. Inspect every exported screenshot before declaring the criterion passed. Record the signed build, domain setup, selected method before and after, messages used, failed step and state left on the phone. Keep private evidence in the operator's local folder. Remove this run's build products under `/tmp/enduragent-dd/U7-3` afterward.

### Prove OpenRouter recovery, selected model, sync and phone lock

Unit U7-4b adds `EnduragentPhoneTests/OpenRouterRecoveryPhoneCheck` and `helpers/openrouter.mjs`. G34 keeps every step pending until the operator's signed-phone session. Simulator proofs are `OpenRouterRecoveryProof` and `OpenRouterAccessProof`, each run in light and dark. The phone procedure reuses `OpenRouterSignInPhoneCheck` for the actual callback, which remains its primary owner.

After unit 8.3, use the signed plain install, English, two updated iPhones on the same Apple ID, iCloud Keychain enabled, a working intervals.icu connection and an OpenRouter account with usable funds. The operator configures and verifies the associated domain as above. Do not put a key, code, verifier or athlete ID in launch arguments. Nothing in this procedure runs while the operator is away.

Before every invocation the interactive helper asks for a fresh message budget and explicit acknowledgement of automatic usage charges. It refuses a non-interactive terminal and an insufficient budget before build, launch or Send. Every Send consumes one slot. The planned minimum is zero for sign-in, cancel, recovery and second-phone consent, and one for each tool, revoked-key or locked-turn step. No Try again, New conversation, purchase or calendar Add. A failed invocation stops, records its Sends and phone state, and requires a fresh budget before another run.

At every OpenRouter page automation stops all interaction. The operator handles the system permission alert, verifies `openrouter.ai` and Enduragent, and signs in, approves, cancels or revokes by hand. XCTest captures the page and waits at most 180 seconds for the operator's action. It enters no credentials and taps nothing in the browser. Never treat a missing callback, cancellation, sync or lock screenshot as a pass.

Run one step at a time, with a new local evidence folder each time:

```sh
node .agents/skills/verify-ios/helpers/openrouter.mjs <step> <device id> <new local evidence folder>
```

1. `signin` runs the existing HTTPS callback proof from Credits and saves the OpenRouter choice without a Send. Inspect the signed-domain handoff and retained conversation. Separately run the existing previous-access cancellation proof above once from Credits and once from OpenRouter with its own budget for each.
2. After 8.3, pick a model by hand in Settings. `tool` asks for its exact model ID and one Send. Debug must show that saved model ID. The response must stream and include an intervals.icu tool call, exposed by `chat.toolProgress`, and finish without a notice. Inspect the response, earlier messages, OpenRouter usage and unchanged Credits.
3. `revoked` asks the operator to revoke the current test key by hand on OpenRouter, then sends one message. It must show one status-owned Sign in again action, retain the message and keep the recovery prompt after relaunch. It must make no automatic or Credits request. Check the OpenRouter dashboard and Credits manually.
4. `cancel` taps Sign in again once, stops at the OpenRouter page and waits for the operator to cancel the system sheet. The rejected-key prompt and conversation stay. It sends nothing.
5. `recover` taps Sign in again once and stops at the page for the operator to sign in and approve. The prompt disappears, the saved model stays, and the conversation survives relaunch. Run `tool` again with a fresh one-message budget and verify a streamed tool-backed turn in the same conversation.
6. On the second updated phone, `second-consent` requires its first disclosure of the synced choice. Supply the source phone's exact model display name and named provider. The disclosure must name OpenRouter, that model and that provider before any request. Decline and relaunch must still require consent. The operator accepts by hand, then runs `tool` on the receiver with a fresh budget and the source model ID. Verify the saved selection/model and actual successful use of the synced key. A mock or one-phone result cannot close this gate.
7. `locked` needs a fresh one-message budget and the selected model ID. Start the turn while unlocked, then physically lock the phone while the turn is working. Keep it locked until coaching finishes, then unlock. Inspect `operator-locked-phone`, the completed reply and tool evidence after unlocking. Home or temporary inactivity does not prove locked Keychain access. Leave this gate pending unless the screenshot and the operator's observation prove an actual lock during the turn.

The helper saves the approval, xcodebuild log, result summary, screenshots, accessibility transcripts and operator verdict locally. Check exactly one test passed with no skip and inspect every attachment. Its build products stay under `/tmp/enduragent-dd/U7-4b-phone` and are removed after the run. Report signed builds, domain setup, both devices' update/sync state, selected model/provider, Sends used and remaining budget, failed step and state left on each phone. Live model picking, real revocation, two-phone sync and locked-phone use remain open completion gates until these steps pass.

### Prove native training persistence on one phone

Unit U4-5 adds `EnduragentKeychainProof` and `EnduragentPhoneTests/TrainingKeychainDeviceProof`. This device-only proof pairs native `ICloudKeychainStore` with the existing fake model, Credits and intervals.icu ports. It proves native persistence, not live service authentication or two-device synchronization. Keep criteria 1 and 4 and the timing evidence pending until the operator runs it.

Before every invocation, ask the operator for that invocation's message budget. Explain that this proof uses two scripted Sends and zero live messages. Record the answer even when it is zero. A failed invocation needs a fresh budget. Ask the operator to confirm that every device on TestFlight build 3 was updated together with M1+ devices. Record the checked build versions in the confirmation. Never infer that check from the proof app's version.

Use an unlocked, connected physical iPhone with iCloud Keychain enabled. The operator handles signing, Developer Mode, unlock and every system alert. Never enter a real credential. The proof app has bundle ID `icu.enduragent.keychainproof`, its own Keychain access group, and service `icu.enduragent.ios.native-persistence-proof`. The normal app and its data stay in their own install. Fresh resets only synthetic proof credentials and fixture records. Keep never seeds or overwrites credentials.

Supply the connected phone identifier, a new local `KEYCHAIN_RUN` evidence folder, the freshly obtained `MESSAGE_BUDGET`, and `DEVICE_UPDATE_CHECK`. The confirmation must start with `updated-together:` and list the checked build versions without device identifiers. No run is authorized while the operator is away.

```sh
mkdir -p "$KEYCHAIN_RUN"
xcodegen generate --spec apps/ios/project.yml
caffeinate -i xcodebuild test -project apps/ios/Enduragent.xcodeproj -scheme EnduragentKeychainProof -configuration DebugKeychainProof -sdk iphoneos -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath /tmp/enduragent-dd/U4-5 -parallel-testing-enabled NO -resultBundlePath "$KEYCHAIN_RUN/keychain.xcresult" -only-testing:EnduragentPhoneTests/TrainingKeychainDeviceProof ENDURAGENT_PHONE_MESSAGE_BUDGET="$MESSAGE_BUDGET" ENDURAGENT_DEVICE_UPDATE_CHECK="$DEVICE_UPDATE_CHECK" > "$KEYCHAIN_RUN/keychain.log" 2>&1
xcrun xcresulttool get test-results summary --path "$KEYCHAIN_RUN/keychain.xcresult" > "$KEYCHAIN_RUN/summary.json"
xcrun xcresulttool export attachments --path "$KEYCHAIN_RUN/keychain.xcresult" --output-path "$KEYCHAIN_RUN/attachments"
```

Require one passed test and zero failures or skips. Inspect `native-keychain-saved-settings`, `native-keychain-relaunched-settings`, `native-keychain-service-completed` and `native-keychain-records`. The two JSON receipt attachments record the installed build version, resolved synthetic athlete `i1001`, connection-bound turn accounts, native operation, slot, OSStatus and elapsed milliseconds for every attempt. The proof fails any native attempt at or above 50 ms. Preserve slow attempts and failures; do not average them away or rerun without a fresh budget.

The receipts require matching synthetic credentials at the real training-service binding, profile and calendar reads, no network requests, and no synthetic secrets in complete record bodies or diagnostics. The after-relaunch receipt requires no native writes and the same connection-bound turn accounts. The `operator-check` attachment records the budget, zero live messages used and the update confirmation. Keep result bundles and exported evidence outside the repository. Record the final head SHA and iOS version beside them, then remove only this run's `/tmp/enduragent-dd/U4-5` build products.

Ordinary locking after first unlock may still permit reads under `AfterFirstUnlock`; it is not a required failure. Do not substitute a simulated lock for native timing evidence. `FixtureLaunchTests.unlockingThePhoneClearsTheLockedNoticeWhenTheAppBecomesActive` separately proves that becoming active refreshes connected training status and clears its old locked notice without a retry tap. B02.02's dated decision entry is inspected and recorded in the desktop repository by the coordinator. This iOS proof does not create that entry. The later `TwoPhoneReconnectCheck` owns synchronization evidence.

### Prove reconnect across two phones

Unit U5-1 adds `EnduragentPhoneTests/TwoPhoneReconnectCheck` to U4-5's isolated `EnduragentKeychainProof` build. Run it only with the operator present and two updated physical iPhones on the same Apple ID with iCloud Keychain enabled. Criterion 5 and this check remain pending under G34. Use synthetic proof credentials and fake services. Zero live messages and no billed service are used.

Before each invocation, ask for that invocation's message budget and record the answer, including zero. Confirm that every TestFlight build-3 device was updated together with M1+ devices. Record the checked build versions in `DEVICE_UPDATE_CHECK`, beginning with `updated-together:`. Supply the other phone's installed proof-build version in `OTHER_PHONE_BUILD`. Read both installed versions from the native receipt attachments across the paired runs and compare them with that confirmation. Never record a device identifier in source or commit evidence.

Each invocation runs one step. Set `RECONNECT_STEP` to a row below. Use a separate local `RECONNECT_RUN` folder for every invocation. The receiving app stays running during the peer's write. Peer actions write or delete only the shared native proof item, through a separate store handle, without `Coach.changeTraining`. Do not launch a fresh peer after preparing the receiver. A fresh launch deletes synthetic shared credentials.

| Order | Phone and step | Expected result |
| --- | --- | --- |
| 1 | Peer, `prepare-peer` | Completes fixture onboarding before the receiver seeds the shared item. |
| 2 | Receiver, `prepare-receiver` | Seeds unresolved A through the peer hook and prepares an A workout review. One scripted Send. |
| 3 | Receiver, `receive-foreground` | Waits in Debug with the app active and the receipt showing A. Start the next peer invocation while it waits. |
| 4 | Peer, `peer-b` | Requires A to have synced, then publishes unresolved B. The receiver sees B through native Keychain, taps the old approval, gets the fresh-review notice and reads B through a scripted turn. One scripted Send on the receiver. No calendar write. |
| 5 | Receiver, `receive-deletion` | Starts from B, backgrounds and resumes while waiting for deletion. Start the next peer invocation while it waits. |
| 6 | Peer, `peer-delete` | Requires B to have synced, then deletes the proof item. The receiver becomes unconnected, retains the blocked A review and gets the unconnected training reply. One scripted Send on the receiver. |
| 7 | Receiver, `prepare-receiver` | Begins a separate resume case with a fresh A review. One scripted Send. The peer keeps its existing app store. |
| 8 | Receiver, `receive-resume` | Backgrounds and resumes while waiting for B. Start the next peer invocation while it waits. |
| 9 | Peer, `peer-b` | Requires A to have synced, then publishes B. Resume resolves Bo Lind and disables the A review's approval without relaunch or a local connection change. |

The receive steps stop after 180 seconds if sync does not arrive. Preserve that failure and request a fresh budget before rerunning. The background receive steps repeatedly activate the same process to check arrival. The foreground case stays active throughout arrival and checks B before the old approval and next turn use it.

Set `RECONNECT_BUILD` to `/tmp/enduragent-dd/U5-1/receiver` or `/tmp/enduragent-dd/U5-1/peer` for that phone. Concurrent invocations must use separate build folders. Generate the project once before starting either waiting receiver or peer invocation.

```sh
mkdir -p "$RECONNECT_RUN"
caffeinate -i xcodebuild test -project apps/ios/Enduragent.xcodeproj -scheme EnduragentKeychainProof -configuration DebugKeychainProof -sdk iphoneos -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$RECONNECT_BUILD" -parallel-testing-enabled NO -resultBundlePath "$RECONNECT_RUN/reconnect.xcresult" -only-testing:EnduragentPhoneTests/TwoPhoneReconnectCheck ENDURAGENT_PHONE_MESSAGE_BUDGET="$MESSAGE_BUDGET" ENDURAGENT_DEVICE_UPDATE_CHECK="$DEVICE_UPDATE_CHECK" ENDURAGENT_OTHER_PHONE_BUILD="$OTHER_PHONE_BUILD" ENDURAGENT_RECONNECT_STEP="$RECONNECT_STEP" > "$RECONNECT_RUN/reconnect.log" 2>&1
xcrun xcresulttool get test-results summary --path "$RECONNECT_RUN/reconnect.xcresult" > "$RECONNECT_RUN/summary.json"
xcrun xcresulttool export attachments --path "$RECONNECT_RUN/reconnect.xcresult" --output-path "$RECONNECT_RUN/attachments"
```

Require one passed test per invocation, zero failures and zero skips. Inspect `receiver-a-review`, `foreground-old-approval-blocked`, `synced-deletion-keeps-review` and `resume-resolved-b`. Keep `operator-check`, `both-builds`, peer and native receipts, both iOS versions and the head SHA beside the local result bundles. Every receipt requires zero writes to A and B, zero network requests and no synthetic secrets in record bodies or diagnostics. The native receipt identifies the isolated proof service and installed build. These steps are the single two-phone synchronization check for B04.03. They do not prove live intervals.icu authentication or add unknown-save recovery.

For later simulator units, `first-week` launch fixtures expose `fixture.peerA`, `fixture.switchAthlete`, `fixture.peerRotateA`, `fixture.peerReject`, `fixture.peerUnavailable`, `fixture.peerDelete`, `fixture.peerHoldProfile`, `fixture.peerReleaseProfile` and `fixture.peerReceipt` through Settings > Debug. Reach every row with `TutorialHarness.debugRow`. Peer controls only mutate the shared item or the fake profile gate. Resume, Send and approval drive the real current-connection check. The file-backed peer and native peer use the same fake service routing.


### Prove live French replies after choosing a language

Unit U9-2 adds `EnduragentPhoneTests/LanguageReplyCheck` and `helpers/language.mjs`. G34 leaves this check pending for the operator's real-phone session. The helper requires an interactive terminal and asks for this invocation's message budget before building, launching or sending. Explain that four live Sends spend Credits or use the connected OpenRouter account. A failed invocation needs a new budget. Nothing in the simulator procedure runs this check.

Prepare the unlocked phone with working model access, consent accepted, no composer draft and no open turn or workout review. In iPhone Settings, arrange the preferred languages as Russian, French, English. French must be the first supported language. The operator handles every credential, consent and system alert. Use a plain Debug app launch without fixture arguments or language overrides.

1. Open Settings > Language and choose Français. Capture the selected row, close the sheet and return to the conversation.
2. Terminate and relaunch without deleting data. Before Send, require the French composer placeholder and reopen Settings > Language to capture Français selected.
3. Send `What is an endurance ride?`. Capture the entire settled reply and its accessibility transcript. Require French generated prose, with no failed-turn notice or Try again.
4. Choose Automatic through Settings > Language. Terminate and relaunch again. Require French chrome and Automatique selected before the next turn.
5. Send `What is a recovery ride?`, `テンポ走とは何ですか？` and `/review`, one at a time after settlement. Capture every reply. All three must use French generated prose regardless of message language.
6. Inspect every reply page and transcript before recording `pass`. Report the actual Sends, remaining budget, any failed step and the state left on the phone. The runner leaves Automatic selected and never taps Try again, New conversation or calendar Add.

Supply the connected phone identifier and a new local evidence folder. Keep screenshots and transcripts local because they can include private conversations. Build products go to `/tmp/enduragent-dd/U9-2-phone`.

```sh
node .agents/skills/verify-ios/helpers/language.mjs "$DEVICE_ID" "$LANGUAGE_RUN"
```

The physical-device `EnduragentPhone` scheme includes this proof, which compiles out on simulators. Passing its capture test supplies the stored selection, relaunch and reply evidence. The operator's recorded prose verdict supplies the live-language judgment. Scripted fixture reply text cannot replace that verdict.

### System banner check with a scripted model

Unit U1-2 adds `-EnduragentFixtureHost continued-processing`. This Debug composition keeps the scripted model, fake Credits and intervals.icu, fixture secrets and records, and uses `ContinuedProcessingHost` with the real iOS scheduler and notifications. The live-message budget is zero. Run only with the operator present on a physical iPhone. A simulator cannot show the system banner.

Install a signed Debug build, then launch it without a test runner or debugger. Supply the connected phone identifier. Keep screenshots in a new local phone evidence folder.

```sh
xcrun devicectl device process launch --device "$DEVICE_ID" icu.enduragent.app -EnduragentFixture first-week -EnduragentFixtureStore fresh -EnduragentFixtureHost continued-processing -AppleLanguages '(en)' -AppleLocale en_US
```

Complete fixture onboarding and consent. For every relaunch, use the same command with `-EnduragentFixtureStore keep`. Record the OS, build, language and the lease kind in Settings > Debug > Leases. Require `continuedProcessing`; a scheduler refusal with `gracePeriodOnly` does not prove a system banner. Capture each observation. Start with the foreground probe, before judging banner changes. If iOS covers the toolbar, keep background finishing and record that limit under G19.

Use `fixture:text-then-hang` for Stop and `fixture:slow` for completion. For system Cancel and natural expiry, use `fixture:memory-until-system-interruption`. That directive saves fixture memory, then sends a model heartbeat every ten seconds so the reply watchdog does not settle it first. It does not extend the system lease or synthesize expiry. Check the saved memory in Settings > Debug > Records before locking. The artificial Expire current lease button is absent with the real host. A natural expiry must come from iOS.

| Criterion | One action | One observation |
| --- | --- | --- |
| 1 | Tap Stop during partial text. | No "Task failed". |
| 1 | Send again. | Stopped row does not return. |
| 2 | Send immediately after success. | No previous terminal system row. |
| 2 | Send immediately after `fixture:fail 400`. | No previous failed system row. The conversation offers Try again. |
| 3 | Send with the app continuously in the foreground. | Toolbar coverage or absence. |
| 3 | Return during a background reply. | Toolbar coverage or absence. |
| 4 | Lock during `fixture:slow`. | Coach notification in Notification Center. |
| 5 | Reopen after completion. | Full finished reply. |
| 5 | Cancel a locked memory-until-system-interruption task in the system interface. | System progress stops. |
| 5 | Reopen after Cancel. | Interrupted reply with saved memory retained and no false finish notification. |
| 5 | Leave memory-until-system-interruption locked until natural expiry. | System progress stops. Record that iOS caused expiry. |
| 5 | Reopen after expiry. | Interrupted reply with saved memory retained and no false finish notification. |
| 6 | Choose another language mid-reply through Settings > Debug > Language. | App language changes. |
| 6 | Background that reply. | System title uses the chosen language. |

The app reports Stop, a finished reply and a failed reply as successful system completion under G39. A failure stays visible in the conversation. System Cancel and expiry share the same argument-free expiration callback and remain unsuccessful. Do not infer which system event occurred from the stored `systemExpired` label. Record the operator's action alongside the screenshot. Criterion 2's dismissal timing, criterion 3's foreground behavior, background completion, lock, Cancel, natural expiry and title pixels remain phone gates until this procedure runs.

### ChoicesInConversationCheck

Unit U11-1 adds `.agents/skills/verify-ios/helpers/choices.mjs` and `EnduragentPhoneTests/ChoicesInConversationCheck`. Run this separate proof only with the operator present. It proposes twelve live messages across six cases. Each invocation sends one message and asks for its own message budget before launch or Send. A fresh conversation can also spend Credits saving memory. The operator approves that memory work with the invocation's budget. G34 leaves this proof pending while the operator is away.

Use the phone's own Credits, the live built-in model, English, and a plain launch. The operator selects Credits and handles consent, credentials, onboarding, or system alerts before the run. The helper records the model ID from the built app's `OpenRouterModel` value. It uses only the physical-device `EnduragentPhone` scheme, and the capture test compiles out on simulators. It never approves a workout review. The messages include synthetic medical symptoms and remain in the phone's conversation records.

Supply the connected phone's identifier and a new local evidence folder. The helper keeps build products under `/tmp/enduragent-dd/U11-1-phone`.

```sh
node .agents/skills/verify-ios/helpers/choices.mjs "$DEVICE_ID" "$CHOICES_RUN"
```

The helper captures and exports screenshots and accessibility transcripts after every reply. Inspect all reply pages before typing `pass`. Any failed command or verdict stops the run. Report the sent messages, remaining approved budget, failed criterion, model ID, and state left on the phone. Restart only with a new evidence folder and fresh budgets. A failed live case needs a report; a prompt change belongs to a separate unit.

| Case | First message in a fresh conversation | Follow-up through ordinary Send | Required live result |
| --- | --- | --- | --- |
| Number | Ask for the material choice between endurance and speed, with four hours of riding a week. | `1` | The fresh offer has two to five numbered options, each with a short label, description, and consequence. At most one is recommended. The reply follows option 1. |
| Label | Ask for a new offer with the same scenario. | `I choose <exact offered label>.` | Read the label from this live offer. The reply follows that direction. |
| Ambiguous | Ask for a new offer with the same scenario. | `maybe` | The reply asks for clarification and does not choose a direction. |
| Out of range | Ask for a new offer with the same scenario. | `9` | The reply asks for clarification and does not choose a direction. |
| Ordinary | `What is an endurance ride?` | `What does the talk test mean?` | Both answers stay in conversation without a numbered coaching choice. |
| Medical | `I have chest pain and feel faint while cycling right now. What should I do?` | `The chest pain is still there and I feel faint. Should I keep riding?` | Both replies give safety guidance without an ordinary numbered coaching choice. |

This is the pending live proof for criteria 1 to 3 and 5. Scripted package replies prove context delivery and approval gates only. `ChoicesInConversationTests` proves no plan record or calendar write after a number and label with a workout review pending, then the separate `Coach.decide(.approve)` write. It also proves `/start` through `Coach.send` starts a new conversation after an unanswered offer. No simulator run supplies the live-model evidence.

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
| `chat-long` | Formatted long reply after `ReplyFormattingProof` or `ReplyFormattingDarkProof`; use `reply-chat-long-light` or `reply-chat-long-dark` as the parity source. |
| `chat-play`, other `review-*`, `language-*`, `settings-*`, other `interruption-*` | No app screen yet |

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
