---
name: verify-ios
description: Drive the Enduragent iPhone app, the SwiftUI app in apps/ios, on a dedicated iOS 26 simulator in fixture mode the way an athlete taps through it, and keep screenshots, xcresult bundles, and the fixture request count as proof. Use to prove an iOS UI change, reproduce a phone bug on the simulator, run the XCUITest proofs on an isolated simulator, or compare a screen with the approved native prototypes.
---

# Verify the Enduragent iPhone app

The surface is the iPhone app built from `apps/ios/project.yml`. Every simulator verification run creates its own simulator, `enduragent-verify-<run id>`, from the newest iOS 26 runtime. The default device is iPhone 17e, which is 390 × 844 points, the same viewport as the prototype captures. Never drive a simulator the run did not create. Physical-device verification uses only the separate procedures in [phone.md](phone.md).

Simulator proofs run in fixture mode, `-EnduragentFixture first-week`. `AppServices.fixture` swaps intervals.icu, credits, the model transport, the keychain, and the record store for fakes. The fakes keep their state on disk under the app's `Application Support/fixture/` and in the `UserDefaults` suite `icu.enduragent.fixture`, so a relaunch can either wipe it (`-EnduragentFixtureStore fresh`, the default) or reuse it (`-EnduragentFixtureStore keep`). Nothing blocks or counts `URLSession` traffic: the hosted test `FixtureLaunchTests.fixtureArgumentBuildsCoachFromFakes` proves that the Coach built for fixture mode reaches the fake model, credits, and intervals.icu clients. No API key, account, or network is needed.

Every simulator step goes through one helper, the `sim` executable of the Swift package in `tools/`. Run it with `swift run` from the checkout you are verifying. It resolves the source tree from the package it was built in, without git, so an exported tree and a shell started elsewhere both work. Source manifests walk `apps/ios` and omit generated projects and build caches. An export needs no symlink or temporary git repository. Set `ENDURAGENT_VERIFY_REVISION` to the exported commit SHA to record its provenance. Without it, `run.json` says `exported-tree` and records a source digest.

```sh
swift run --quiet --package-path tools sim build
swift run --quiet --package-path tools sim create onboarding
swift run --quiet --package-path tools sim doctor <run id>
swift run --quiet --package-path tools sim install <run id>
swift run --quiet --package-path tools sim test <run id> FirstConversationProof
swift run --quiet --package-path tools sim cleanup <run id>
```

Every command accepts `--build-folder <path>`. The flag overrides `ENDURAGENT_VERIFY_BUILD`; both default to `<tree>/DerivedData`. Use the same folder for build, doctor, install, and test. Put builds under `/tmp/enduragent-dd/`, for example `ENDURAGENT_VERIFY_BUILD=/tmp/enduragent-dd/<task>`.

Below, `sim` means `swift run --quiet --package-path tools sim`. The first call builds the helper into `tools/.build`, and later calls reuse that build. `create` prints the run id, for example `2026-10-01-120000-a1b2c3d4-onboarding`. Commands for that simulator take its run id.

The feature map in [features/README.md](features/README.md) is the recipe for each feature. A proof that drives one convenient entry point is incomplete when the feature file lists others.

## Launch

1. Build once per checkout with `sim build`. It runs `xcodegen generate --spec apps/ios/project.yml`, then `xcodebuild build-for-testing` with the README flags: the generic simulator destination, `-derivedDataPath DerivedData`, and `CODE_SIGNING_ALLOWED=NO`. The build-folder option replaces `DerivedData` in those paths. It also builds the UI test runner that `test` needs. The log is `DerivedData/verify-ios-build.log`. Before it builds, it records the SHA-256 of every source under `apps/ios`, and after a successful build it writes them to `DerivedData/verify-ios-sources.json`. The generated `Enduragent.xcodeproj` is ignored by git, so a change to sources or `project.yml` leaves no project file to commit. `make project` regenerates it for Xcode.
2. Create the run with `sim create <kebab-slug>`. It creates and boots the simulator, waits for `simctl bootstatus`, sets the status bar to 9:41 with full signal and battery like the prototype captures, sets light appearance, and writes `run.json` into the evidence folder. The first boot takes about a minute.
3. Install with `sim install <run id>`. Install again after every build.
4. Launch with `sim launch <run id>`. It runs `xcrun simctl launch --terminate-running-process <udid> icu.enduragent.app -EnduragentFixture first-week -AppleLanguages (en) -AppleLocale en_US -EnduragentFixtureStore fresh` and prints `icu.enduragent.app: <pid>`. The app is ready when `sim shot <run id> notice` shows the notice text `Training suggestions, not medical advice. Check with a doctor before big changes.` and `Continue`. `sim launch <run id> --keep` passes `-EnduragentFixtureStore keep` instead, which reopens the app on the state the last launch left: after onboarding and a reply it opens on the chat with the transcript. Other arguments after the run id pass through to the app, for example `-EnduragentFixtureKeychain locked`, which makes every keychain read throw as a locked iPhone would, `-EnduragentFixtureKeychain empty`, which leaves the fixture keychain without a Credits key, `-EnduragentFixtureStore unreadable`, which wipes the fixture and makes the record store fail to open so the app shows `launch.storageUnavailable` instead of the notice, `-EnduragentFixtureCoalescing <milliseconds>`, which replaces the 1.5 second window in which a second message joins the first, `-EnduragentFixtureRecovery unreadable`, which makes the launch recovery's read of earlier claims fail so a reply cut off by a kill stays unsettled, `-EnduragentFixtureHost "expire-after 3"`, which makes the fixture's execution host expire every lease three seconds after it begins, as iOS would when it stops the app's background work, and `-EnduragentFixtureClock 1998-06-16T04:20:00Z`, which starts the fixed clock at that ISO 8601 instant instead of `1998-06-15T08:00:00Z`. XCUITest needs about two seconds between two Send taps, so proofs that need a joined turn, a shot before the reply, or a kill before the claim pass `TutorialHarness.launch(app, coalescingMilliseconds:)`.

The first launch on a new simulator can block for minutes while first-boot services run and the home screen still shows blank icons. Check `uptime` before you suspect the app, and let the command finish. Launching again terminates the app and opens it again. Teardown is **Cleanup**.

Two runs can drive side by side, because each has its own simulator and run id. They share the checkout's single build, so never run two builds in the same checkout at once.

## Doctor

Run `sim doctor [<run id>]` first, and again whenever a screen or command looks wrong. It is read-only. It checks Xcode 26, an iOS 26 runtime, the device type, XcodeGen, the app build and its bundle id `icu.enduragent.app`, that every source under `apps/ios` has the content the last `sim build` built, the UI test runner, and the prototype captures. With a run id it also checks the evidence folder, that the simulator is booted, that the app is installed, and whether it is running. Exit 0 means the run is worth driving.

- `FAIL stale build` names the first source whose content differs from the last build, or says the build wrote no source manifest. Run `build`, then `install`. Touching a file without changing it does not fail the check, because Xcode skips unchanged content and does not relink the app. A failing doctor stops the run: fix the cause and rerun doctor before any proof.
- `note verify simulator ...` lists every `enduragent-verify-*` simulator. Report the ones your run did not create. Delete only your own.

## Drive

XCUITest finds controls by accessibility identifier. The interactive tool taps by coordinates, so find each control in a fresh screenshot by its visible label and name its identifier from the table below in your report.

**XCUITest proofs.** This is the scripted harness and the default. In `apps/ios/EnduragentUITests/`, classes ending in `Proof` hold the UI proofs. `sim suite` discovers them from the Swift sources. Classes ending in `Probe` are timing probes: `LaunchLatencyProbe` and `HistoryOpenProbe` in `LaunchProbes.swift`, `SendLatencyProbe` in `TurnProofs.swift`, and `FailNoticeLatencyProbe` in `FailureProofs.swift`. `apps/ios/Enduragent/Fixtures/FixtureArguments.swift` builds the launch arguments. `TutorialHarness.swift` holds the shared steps `launch`, `send`, `exchange`, and `openSettings`, and `TutorialOnboarding.swift` holds `completeOnboarding`. Each feature file names the proofs that cover it. Run them with `sim test`, described in **UI test run**. A state that no proof reaches gets a new proof in the file for its feature, reviewed with the change it proves. It is Swift, so `make lint-swift` and `make check-format` apply.

**Interactive.** Use this for exploration, paths no proof covers, and parity captures. Start the app with `sim launch`, then drive it with the Claude Code iOS Simulator `control` tool and pass `device: <udid>` on every call. Its default target is the first booted simulator, which can be the operator's own. Never use the tool's own `launch` action: it takes no app arguments, so the app starts outside fixture mode. The tool asks the operator to allow each simulator. When nobody can approve, or the tool is missing, there is no tap path outside XCUITest, so write a proof. `tap` takes device points, 390 wide on iPhone 17e, so scale a position in a screenshot by 390 divided by the image width. `text` types into the focused field. The simulator uses the Mac keyboard as a hardware keyboard, so no on-screen keyboard appears.

| Screen | Handles |
| --- | --- |
| Notice | `notice.continue` |
| Record store unavailable | `launch.storageUnavailable` with `Conversation history is temporarily unavailable.` and `Quit and reopen Enduragent.` |
| Connect | `connect.apiKey`, `connect.connect`, `connect.skip`, `connect.saved`, `connect.notice`, `connect.displayAction`, `connect.athleteName`, `connect.athleteID`, `connect.fitness`, `connect.fatigue`, `connect.form`, `connect.continue` |
| Starter, titled Access method | `starter.useCredits`, `starter.progress`, `starter.credits`, `starter.openRouter`, `starter.start`; Debug builds add `fixture.signInCount` and `fixture.completeSignIn` while a sign-in is held |
| AI-provider consent | `consent.body`, `consent.accept`, `consent.decline`, `consent.error` after a failed consent write, and `consent.resume` after Not now; Debug builds add `consent.modelRequestCount` |
| Chat | `chat.history` labeled with `archive.history`, `chat.settings` labeled with `settings.title`, `chat.newConversation`, the compose icon labeled `New conversation`, `chat.welcome`, `chat.newConversation.notice`, `chat.composer`, `chat.send`, `chat.stop`, `chat.composer.notSent`, `chat.composer.notice` for a coach-wide notice such as a locked Keychain, `chat.working`, `chat.turn.notice`, `chat.turn.tryAgain`, `chat.turn.buyCredits`, `chat.turn.switchToOpenRouter`, `chat.turn.restorePurchases`, `chat.turn.chooseAccessMethod`, `chat.turn.signInAgain`, `chat.turn.receivedBeforeClose`, `chat.turn.finishedWhileLocked`, `chat.turn.connectTraining`, `chat.turn.saveFailure` for a reply that could not be saved, `chat.turn.reviewNotice` for a workout review the turn could not prepare, `chat.access.notice`, `chat.access.signInAgain` and `chat.access.outcome` for a rejected OpenRouter key, `chat.note` for a durable review outcome with one line per change and `chat.note.closing` for its closing sentence, `chat.review.notice` for a review action result, `chat.review.connect` for missing training connection guidance, `chat.slash.<command>`, `chat.transcript` for the List, `chat.composer.container` for the whole composer; `ReviewCardComposerProof` checks row separation and hittable Send with the keyboard open |
| Chat turn probe | Debug builds expose the invisible `chat.turnProgress` element with accessibility value `turns <count> settled <settled count>`. `TutorialHarness.exchange` reads it before sending and waits for one more turn with every turn settled. |
| Language sheet | `language.choice.<automatic or tag>` with the selected trait on the current choice, `language.close`, `language.saveFailed` |
| Settings language | `settings.language` opens the same sheet as `/language`, showing the saved preference in the row |
| Records | `debug.records` in Debug, `records.list`, `records.device` at the top, `records.entries` after the counts, `records.count.<kind>`, `records.row.<id>` whose label names a `turnSettled` row's outcome such as `interrupted processEnded` or a `turnClaim` row's lease kind, `gracePeriodOnly` for every new claim or `continuedProcessing` for a claim saved before 2026-10-16, and ends with the row's training account, `unconnected` or `intervals:<connection id>:<athlete id>`, and the toolbar `Refresh` button identified by `records.refresh` |
| Leases | `debug.leases` in Debug, `leases.row.<n>` whose label reads like `athlete gracePeriodOnly finished`, and the `Refresh` button with no identifier |
| Workout review | `chat.preview.title` in the review's first transcript row, above the cards, with `chat.preview.preparedEarlier` under it for a review carried into a new conversation; in `chat.review.bar`, docked above the composer or, at accessibility text sizes, closing the review in the transcript: `chat.review.totals`, `chat.review.question`, `chat.review.status` for the unseen or failed-card sentence, `chat.review.showAgain`, and `chat.preview.cancel`, `chat.preview.add`, `chat.preview.tryAgain` and `chat.preview.checkAgain`, one layout per control set, none present until every card has appeared and the token arrives, and shown disabled while the review cannot be read; one `chat.preview.card.<index>` per change, each in its own transcript row, holding `chat.preview.card.title`, `.heading`, `.status`, `.change`, `.steps` and `.load`, and `chat.preview.card.chart` holding `.chart.unit`, `.chart.tick` and `.chart.time` with its drawing hidden from accessibility; `chat.preview.kept` under the last card holding `.kept.title`, `.kept.day` and `.kept.workout`; `chat.preview.finished` holding `.finished.title`, `Already completed`, and one `.finished.line` per finished change; `chat.review.notice` for a stage notice, such as a refreshed, partial, blocked or account-changed review; `chat.preview.notice` only for `review.storageUnavailable`, when the review cannot be read or a step cannot be recorded. The chat disclaimer under the composer, or closing the transcript at accessibility text sizes, has no identifier. |
| Settings | `settings.accessMethod`, `settings.model` when model choices are loaded, and `settings.credits` under Model access, `settings.training` under Training connection, `settings.debug` in Debug builds only; Back from Model access Credits returns here |
| Credits | `credits.balance`, `credits.pack.<product id>`, `credits.note`, `credits.notice`, `credits.switchToOpenRouter`; Back returns to the entry point, Settings or the conversation notice |
| Training connection | `settings.training`, `training.edit`, `training.apiKey`, `training.save`, `training.keep`, `training.cancel`, `training.disconnect`, `training.saved`, `training.notice`, `training.athlete`, `training.athleteID`, `training.fitness`, `training.fatigue`, `training.form`, `training.displayAction`; owner and disconnect confirmation alerts. Fixture-only Debug handles are `fixture.connection`, `fixture.failCredentialWrite`, `fixture.toggleKeychainLock`. |
| History | `history.content`, `history.row.<boundary or chat id>` with `history.date.<id>` and, after two athletes, `history.athlete.<id>`; then `archive.content`, `archive.note` for workout review outcome lines, and `archive.readOnly` in the pushed conversation |
| Debug | `debug.accessModel` with the saved model ID or `unavailable`, `fixture.modelRequestCount`, `fixture.historyHead` (the first line of the history the last reply was sent with), `fixture.replyLanguage` (the first line of the reply-language section the last reply was sent with), `debug.language`, `fixture.failNextAppend`, `fixture.expire`. The [feature map](features/README.md) lists the other Debug rows. |
| Session (Settings) | `settings.session`, `session.<field>.input`, `session.<field>.unit`, `session.<field>.rejection`, `session.save`, `session.cancel`, `session.saveFailed`, where `<field>` is `historyBudgetRatio` or `contextWindowOverride` |

The fixture athlete is Ada Kovač, athlete `i1001`. The key `other-athlete` resolves to Bo Lind, athlete `i2002`. The peer hook also supplies rejected and unavailable keys. Other non-empty keys resolve to Ada. The fixture keychain starts with a Credits key and no intervals.icu connection, so the chat is unconnected until the connect step or Settings > intervals.icu stores a key. The fixed day is 1998-06-15. The connect screen shows `Fitness 42`, `Fatigue 49`, and `Form -7`. The starter grant and the balance are 200 credits. The packs are 500 and 2000 credits with purchases disabled. `FirstWeekFixture.script(for:offersTrainingTools:)` picks the coach reply from the message text. `/review` gets the Saturday group ride summary. `/workout` and `/status` get the text replies in the table below, whatever text follows the command. Text starting with `Remember that` gets `Noted. I'll remember you ride with a group on Saturdays.` Text containing `endurance ride` or `60 minute endurance` gets a workout review when intervals.icu is connected, and a reply about the missing training data when it is not. Anything else gets the week summary. The [workout review page](features/workout-review.md) lists the `fixture:review-` directives, and the [conversation page](features/chat.md) the formatting, number, step-limit and tool-progress directives.

A message that starts with `fixture:` is a directive to the fakes, typed into `chat.composer` like any message. `FakeModelTransport` asks the closure from `FirstWeekFixture.responses(intervals:credits:)` for each attempt when its request executes:

| Message | Effect |
| --- | --- |
| `fixture:slow` | Waits 2 seconds, then streams the week summary one word every 250 ms, so `chat.working` shows for 2 seconds and the growing reply for about eight more. |
| `fixture:slow-flush` | The reply to this message and the next memory save each wait 6 seconds before answering, until another chat request executes. `New conversation` right after it shows `chat.working` under the old conversation for about 6 seconds. |
| `fixture:hang` | The model never answers. The 30 second watchdog fires, the coach retries once, the watchdog fires again, and the turn fails with `coach.error.providerDown` after about 60 seconds. |
| `fixture:fail 500`, `fixture:fail 400`, `fixture:fail 401`, `fixture:fail 402`, `fixture:fail 403`, `fixture:fail 429`, `fixture:fail 429 7`, `fixture:fail network`, `fixture:fail timeout`, `fixture:fail overflow`, `fixture:fail finish` | The next model request fails before any reply text with the HTTP status, connection error, or stream end the directive names, parsed by the same rules as the real transport. `429` carries a `retry-after` of 7 seconds and `429 <seconds>` that many; `finish` is an unknown finish reason. A trailing `xN`, as in `fixture:fail 429 7 x4`, fails the next N requests. The coach retries retryable failures with real waits, so the notice needs `x3` for `500` and `network`, `x2` for `timeout`, and `x4` for `429` and `overflow`. |
| `fixture:memory-then-fail` | The model saves a `schedule` memory section, then the next request fails with a 500. The turn ends with a notice and no `Try again`, because information was saved. |
| `fixture:memory-then-hang` | The model saves a `schedule` memory section, then the next request never answers. Tapping Stop settles the turn with `This reply stopped before it finished. Some information was saved first.` and no `Try again`; left alone, the watchdog ends it after 30 seconds with the saved-work notice. Killing the app instead reopens it with the same sentence and Records lists `turnSettled` as `interrupted processEnded`. |
| `fixture:text-then-hang` | The model streams `This week has Tuesday sweet spot` and then stops answering. Records lists `replyObserved 1` while the text is on screen. After 30 seconds the watchdog ends the turn with `coach.error.providerDown` and no retry, because reply text was already shown. Killing the app while the text shows reopens the turn with `This reply stopped before it finished. Nothing was changed.` and `Try again`, no reply text, and no model request. |
| `fixture:teach` | The model saves a `schedule` memory section, then replies `Noted. I'll remember you ride with a group on Saturdays.` |
| `fixture:long` | The reply is the week summary written out for 100 days, about 5,200 tokens, so a few messages reach the soft flush gate and the trim. |
| `fixture:flush-partial` | Replies with the week summary and arms the next memory flush to save a `schedule` section and a `ledgerEvent`, then fail, so its job stays pending until the next launch. `fixture:fail overflow` right after it triggers that flush inside the overflow turn. |
| `/workout` or `/status`, alone or with text after it | The model waits 8 seconds before its first word, so `chat.working` shows under the message, then replies in text: a 45 minute easy ride for `/workout`, Fitness 42, Fatigue 49 and Form -7 for `/status`. No workout review follows. |
| `/workout fixture:lost`, `/status fixture:lost` | The model streams `Ride 45 minutes at ` and the connection is lost. The turn fails at once with `coach.error.providerDown` and Try again, because reply text was already shown. Try again gets the text reply. |

Queued messages keep separate scripts and delays. An unknown directive, such as `fixture:fail bogus`, gets an assistant reply saying `Unknown fixture directive: <message>`.

Debug has two conversation fault controls. `fixture.failNextAppend` arms the next record append failure; send a message afterward to check that its draft survives acceptance failure. `fixture.expire` expires open leases without sending a message. Running turns settle as interrupted with `systemExpired`; queued turns settle as stopped before start. Model overrides are absent from Settings > Session, and older synced model IDs are ignored.

**Launch arguments.** `sim launch <run id>` puts the arguments after the run id behind its own `-EnduragentFixtureStore fresh`, and the app keeps the last value of a repeated key, so `sim launch <run id> -EnduragentFixtureStore unreadable` opens on `launch.storageUnavailable`. Proofs build their arguments with `FixtureArguments`. The feature pages give most hooks in raw form. These are the rest:

| Argument | Values | Effect |
| --- | --- | --- |
| `-EnduragentFixtureReviewStage` | `sending`, `partial`, `unconfirmed`, `refreshed`, `blocked`, `storage` | Sets the fakes for one stage of `fixture:review-mixed`; the [workout review page](features/workout-review.md) describes each under `FixtureArguments(reviewStage:)` |
| `-EnduragentFixturePresentation` | `fail-last-card-once` | The last card fails to appear the first time the review is presented |
| `-EnduragentFixtureCalendarSave` | `lose-answer-once` | The first calendar write lands, but its answer is lost |
| `-EnduragentFixtureCalendarRead` | `fail-once` | The next calendar read fails once |
| `-EnduragentFixtureRecordRead` | `fail-after-presented-once` | One record read fails after the review is presented |
| `-EnduragentFixtureReset` | `failBoundary` | The New conversation boundary write fails |
| `-EnduragentFixtureStore` | `v1-history`, `v1-review`, `pre-vault-5de5c782`, `build-6833d90f-open-review`, `build-6833d90f-unknown-write`, `build-6833d90f-completed` | Copies a committed upgrade store before the store opens, as **Upgrade proofs** describes |
| `-enduragent.onboardingCompleted` | `YES` | Skips the notice, connection and starter steps; AI-provider consent still comes first |
| `-UIPreferredContentSizeCategoryName` | `UICTContentSizeCategoryAccessibilityXXXL` | The largest accessibility text size |

## UI test run

```sh
swift run --quiet --package-path tools sim test <run id> FirstConversationProof
```

Pass one or more proof classes, or `Class/testMethod`. The helper runs `test-without-building` against the products of `sim build`, so several test runs share one build. After a source change, run `build` and `install` first. The doctor flags a stale build. The command is:

```sh
xcodebuild test-without-building -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -destination id=<udid> -derivedDataPath DerivedData -parallel-testing-enabled NO -resultBundlePath <evidence>/uitest-<stamp>.xcresult -only-testing:EnduragentUITests/FirstConversationProof
```

The helper first terminates a running copy of the app, because XCUITest cannot terminate an app that `sim launch` started and the proof would fail with `Failed to terminate icu.enduragent.app`. `-parallel-testing-enabled NO` stops xcodebuild from cloning the simulator, because a clone would escape cleanup. The result bundle, Xcode's full recording of the test run, lands at `/tmp/enduragent-verify-recordings/<run id>/uitest-<stamp>.xcresult`. Set `ENDURAGENT_VERIFY_RECORDINGS` to move that root. It is the large part of a run, and `/tmp` is the one place an agent may delete it. In the evidence folder `~/Library/Logs/enduragent-verify/<run id>/` the helper writes the xcodebuild log `uitest-<stamp>.log`, the summary `uitest-<stamp>-summary.json`, and the exported screenshots in `uitest-<stamp>-attachments/` with `manifest.json`. It prints `Passed` or `Failed` with counts, then one `attachment <test> <name> <path>` line per screenshot, where `<name>` is the name the proof gave `TutorialHarness.attach`. On an xcodebuild failure it prints the tail of the log and exits 1. Failed, skipped, or missing test results also exit 1, even when xcodebuild exits 0. It saves the result tree as `uitest-<stamp>-tests.json` and the per-class counts as `uitest-<stamp>-classes.json`.

To prove state across a kill and reopen, call `TutorialHarness.relaunchKeepingStore(app)` inside one proof. It terminates the app, asserts `.notRunning`, swaps `fresh` for `keep` in the launch arguments, launches, and waits for `.runningForeground`. `RelaunchKeepsChatProof` is the model: onboard, send the week question, relaunch, then assert the question and the reply are back and the notice is not. Assert the screen and content the athlete sees, never only that the app came back. `XCUIDevice.shared.press(.home)` followed by `app.activate()` backgrounds and resumes the app without a kill. The interactive equivalent is `sim launch <run id> --keep`; without `--keep` the launch wipes the fixture store and opens on the notice.

**Hosted app tests.** `EnduragentTests` runs Swift Testing suites inside the app on a simulator, such as the `FixtureLaunchTests` cases the feature pages name. `make test-app` picks the first available iPhone simulator, which can be the operator's, so run its command against your run's simulator instead. Take the udid from the run's `run.json`:

```sh
xcodebuild test -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath /tmp/enduragent-dd/<task>-app-tests -only-testing:EnduragentTests/FixtureLaunchTests CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

`-only-testing:EnduragentTests` runs the whole target.

**Every proof split across owned simulators.** One command builds once, discovers every UI proof class, splits them across two simulators, and deletes both after the run:

```sh
caffeinate -i swift run --quiet --package-path tools sim suite --build-folder /tmp/enduragent-dd/<task> --shards 2
```

Change `--shards` to choose N simulators. Append class names to run a subset, for example `suite --shards 2 FirstConversationProof ReviewUpgradeProof`. A suite takes classes, not individual methods. Each shard runs with `-parallel-testing-enabled NO` on every xcodebuild call. A shard deletes its simulator whenever its `run.json` exists, so cleanup also follows a failed proof or boot. The coordinator waits for every shard and checks cleanup again before reporting.

Each shard has its own `<suite id>-shard-N/` folder with `run.json`, xcodebuild logs, exported attachments, and `summary.json`. Its result bundles are in `/tmp/enduragent-verify-recordings/<suite id>-shard-N/`. The `<suite id>/` folder holds `plan.json`, each worker's log, a combined `summary.json`, a per-class table in `summary.md`, and `timings.json`. Counts include passed, failed, skipped, and missing results. Any failed shard, failed test, skipped test, or missing class makes the command exit 1. An infrastructure failure before testing can leave a shard without a result bundle; its summary still names every unverified class. When the first run has at most three failed classes and none skipped or missing, the shard reruns each failed class once, alone, on that same simulator before deleting it. A class that passes on the rerun counts as passed, and its row records how many tests failed the first time. The combined `summary.json` lists those class names under `rerun`, and `summary.md` and the command output add a `Passed on rerun:` line.

Without timings, the planner distributes classes evenly. If `<evidence root>/timings.json` exists, or you pass `--timings <file>`, it assigns the longest measured classes first to the least-loaded shard. The file is a JSON map from class names to positive seconds, for example `{"FirstConversationProof": 82}`. New classes use the mean of known durations. A completed suite writes an updated timing file into its own folder; pass that file to the next run to reuse measurements. An explicitly requested missing or malformed timing file fails before simulator creation.

Discovery takes classes whose names end in `Proof`. Classes that end in `Probe` measure time and run only through `sim test`; `suite` rejects them. Classes that end in `Sweep` are the release sweeps on the [language page](features/language.md) and the [workout review page](features/workout-review.md), and run only when named. `LaunchLatencyProbe` must run `testSeedTwoHundredTurns` before its launch tests, and XCTest runs a class's tests in name order, so in one run the launch tests find no seeded store.

The history and review upgrade proofs use committed stores and must pass with zero skips. Each proof copies a fresh store set before launch, so data left by another proof does not supply its upgrade precondition. A missing fixture resource is a failure.

**Upgrade proofs.** Build the current checkout and run both proofs together:

```sh
swift run --quiet --package-path tools sim build
swift run --quiet --package-path tools sim test <run id> UpgradeHistoryProof ReviewUpgradeProof
```

Require `4 passed, 0 failed, 0 skipped`. `TutorialHarness.launchUpgrade` uses `FixtureArguments` with an upgrade store policy and completed onboarding, then accepts AI-provider consent. Debug fixture preparation copies the corresponding synced and local databases from `apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures/v1-upgrade` or `Fixtures/build-6833d90f` into the app's fixture directory before the store opens.

`UpgradeHistoryProof` opens the history fixture on the welcome and asserts two archived conversations labeled `Earlier chat`. It opens an archive and checks the saved question and reply, the read-only notice, and the absence of composer controls.

`ReviewUpgradeProof` opens the three build 6833d90f stores, each holding one conversation for athlete `i1001`, whose connection the store policy installs. The open review closes once with `This review was prepared before the app was updated. Ask the coach again.` and no control, offline through `calendarReadFault: .failOnce` and again after an online relaunch. The unknown write opens offline with Check again and Cancel; online, the read finds nothing in the empty fake calendar and the card offers Add to calendar and Cancel, and Add to calendar saves it. The completed review keeps its note with no control. Those stores were generated through the frozen code at build 6833d90f by `tools/fixtures/Build6833d90fStoreSeed.swift`; `swift run --quiet --package-path tools upgrade-stores build-6833d90f` regenerates them.

The v1 stores were generated through the frozen v1 code at `82254bbda75ba79b0156d7efd3deac223489b2b0`. To regenerate them on macOS with that code's compatible Swift toolchain, run:

```sh
caffeinate -i swift run --quiet --package-path tools upgrade-stores v1-upgrade
```

The generator archives the frozen package and its unchanged `FirstWeekFixture` into a temporary directory, adds `tools/fixtures/V1UpgradeStoreSeed.swift` to the test target, and drives the v1 `Coach.send` and `SwiftDataRecordLog`. It checkpoints the generated SQLite databases and copies them into the two committed fixture folders. Each run writes new record identifiers and a new store identifier, so the regenerated files hold the same records as the committed ones in different bytes. `upgrade-stores pre-vault-5de5c782` and `upgrade-stores build-2bbe2ee` regenerate two more upgrade fixtures the same way from their frozen commits: the pre-vault stores that `UpgradeConnectionProof` and the package upgrade tests open, and the package-only build 2bbe2ee stores. Do not hand-edit database rows or the frozen schema. CI and UI proof runs consume the committed stores and need no v1 installation or detached worktree.

## Verify on the real phone

[phone.md](phone.md) holds every physical-iPhone check: the scripted phone run, OpenRouter sign-in, recovery and model picking, native Keychain persistence, two-phone reconnect, live French replies, the no-banner check, and choices in conversation. Each runs only with the operator present.

## States fixture hooks cannot reach

These gaps were checked against `FixtureArguments`, `FirstWeekFixture`, and the Debug controls. A package result proves its contract, not pixels. Do not claim a missing screen proof as passed.

| State without a UI hook | Evidence to use instead |
| --- | --- |
| An unconfirmed change read again each time the app becomes active | `CoachLifecycleRecoveryTests.eachBecameActiveReadsTheUnconfirmedChangeAgainUntilItIsFound` and `CheckAgainTests.anUnconfirmedChangeIsReadAgainAtEveryRecover` prove it. On screen, `ReviewLostAnswerProof` reads a lost answer at once and `ReviewUnconfirmedProof` finds it with Check again. |
| No system banner or notification on a real phone, OS suspension or expiry, lock and unlock, and a hard kill losing partial text | The procedures in [phone.md](phone.md) and their screenshots. Home proves backgrounding only. The operator performs an actual lock and unlock. Fixture host expiry proves the package's expiry response, not when iOS expires a real lease. A device run must capture an actual OS expiry before claiming that part. |
| Live networking, real Keychain access or sync, CloudKit imports, and a second device's consent or conversation | The [phone run](phone.md#run-phonerun) plus the operator-assisted [two-phone reconnect](phone.md#prove-reconnect-across-two-phones) on the same Apple ID. The one-phone script does not cover the second device. Fixture stores have CloudKit off. |
| Exactly one intervals.icu event, including UID upsert after an uncertain write | The operator reads the real calendar after the single Add. Repeated-write UID-upsert evidence belongs to the operator's authorized live calendar-save check; this phone script never repeats Add. |
| StoreKit prices, purchases, and Restore | Operator-approved store-release testing. Neither this suite nor the phone script claims that proof. |

## Compare with the prototype

The approved prototypes are HTML. Their native-look captures are 390 × 844 PNGs named `native-<prototype>-<state>-<theme>.png` in `~/projects/enduragent/desktop/docs/prototypes/ios/captures-2026-09-25/`. Set `ENDURAGENT_PROTOTYPE_CAPTURES` to use another folder. Parity is by state and copy, not pixels, because SwiftUI system rendering differs from the HTML. Do not add a pixel-diff tool.

1. Drive the app to the state with the interactive harness.
2. Run `sim parity <run id> <prototype>-<state> <light|dark>`, for example `parity <run id> chat-menu dark`. The helper sets the simulator appearance, waits 1.5 seconds, and writes `parity/<prototype>-<state>-<theme>/` with `prototype.png`, `simulator.png` at 1170 × 2532, and `simulator-390.png` at the prototype's 390 × 844. An unknown state prints every available state. The appearance stays set afterwards.
3. To use a proof screenshot instead, add `--from <attachment png>`. `sim test` sets light appearance before it runs, so proof screenshots are light. Neither the `-AppleInterfaceStyle Dark` launch argument nor `XCUIDevice.shared.appearance` changes the app on the iOS 26 simulator; a poll of `simctl ui appearance` read `light` through a whole proof that set it on 2026-09-27.
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
| `review-ready` | The `Workout review` card after a workout request. For the card content, `u8-1-review-cards-add` after `fixture:review-mixed` from `ReviewCardsAddProof` |
| `review-ready-scroll` | The same review scrolled to its last card, `u8-1-review-cards-add-scrolled` from `ReviewCardsAddProof` |
| `review-canceled-first` | A review canceled before any change was written: the note box with `change not made.` for every change and `The remaining changes were canceled.`, `u8-3-review-canceled-first` from `ReviewBlockedProof` |
| `review-partial` | A run stopped at a refused change: `Already completed` with the saved lines, the remaining cards, the refusal notice and Try again with Cancel, `u8-3-review-partial` from `ReviewPartialProof` |
| `review-retried` | The note box after Try again finished the rest, closing with `All reviewed changes are complete.`, `u8-3-review-retried` from `ReviewRetriedProof` |
| `review-canceled` | The note box after Cancel at a refused change, saved lines then `change not made.` lines and `The remaining changes were canceled.`, `u8-3-review-canceled` from `ReviewCanceledProof` |
| `review-deliver` | The mixed review with every card seen: totals and kept workouts, `u8-2-review-totals` and `u8-2-review-totals-kept` from `ReviewTotalsProof`, and the question and approve label per kind of review from `ReviewApprovalBarProof` |
| `review-arriving` | A long review just arrived with no button yet, `u8-2-review-long-arriving` from `ReviewLongPresentationProof` |
| `review-card-failed` | The bar after the last card failed to present, with Show again and no approve button, `u8-2-review-card-failed` from `ReviewLongPresentationProof` |
| `chat-working` | Within one second of sending `fixture:slow`: `chat.working` reads `Coach is working…` and no reply text yet |
| `chat-streaming` | About three seconds after sending `fixture:slow`: part of the week summary with the working row still under it |
| `chat-failed` | After `fixture:fail network x3`: `chat.turn.notice` under the message reads `The model provider is having trouble — try again in a few minutes.` with `Try again` in `chat.turn.tryAgain` |
| `interruption-accepted` | After `sim launch <run id> -EnduragentFixtureCoalescing 60000`, onboarding, `fixture:hang`, and `sim launch <run id> --keep` before the minute ends: the message once with `Received before the app closed. Tap Try again to send it.` and `Try again`. `AcceptSurvivesKillProof` attachment `accept-kill-reopen` shows it |
| `interruption-draft` | After tapping `fixture.failNextAppend` in Debug and sending a message: the composer keeps the text with `Not sent. Your draft is still here.` under it. `StorageFaultProof` attachment `storage-fault-not-sent` shows it |
| `interruption-completed` | A reply that landed while the app was in the background: the whole reply with `Finished while the phone was locked.` under it, after `FinishedWhileAwayProof` |
| `interruption-interrupted` | The dimmed partial reply with `This reply stopped before it finished. Nothing was changed.` and `Try again`, after `StopProof` or `ExpiryProof` |
| `chat-long` | Formatted long reply after `ReplyFormattingProof`; use `reply-chat-long-light` as the parity source. |
| `language-picker-auto`, `language-picker-fr` | The language sheet with Automatic or Français selected, from `LanguagePickerProof`; the [language page](features/language.md) names the attachments |
| `interruption-calendar-uncertain`, `interruption-calendar-checked` | Closest states: `u8-3-review-unconfirmed` with Check again and `u8-3-review-unconfirmed-seen` after it, from `ReviewUnconfirmedProof`. Their copy and layout differ from the prototype. |
| `chat-play`, other `language-*`, `settings-*`, other `interruption-*` | No app state mapped |

## Evidence

Each run writes to `~/Library/Logs/enduragent-verify/<run id>/`. Set `ENDURAGENT_VERIFY_RUNS` to move the root. The folder is outside the repository, so no screenshot can be committed, and it survives cleanup and worktree removal. Result bundles are kept apart, under `/tmp/enduragent-verify-recordings/<run id>/`. It holds:

- `run.json` with the run id, simulator name, udid, device type, runtime, checkout, revision, build folder, and source digest; git checkouts use `git describe --always --dirty`, and exports use `ENDURAGENT_VERIFY_REVISION` or `exported-tree`;
- `<label>.png` from `sim shot <run id> <label>`;
- the UI test files described in **UI test run**;
- `parity/<prototype>-<state>-<theme>/` from `sim parity`.

The helper uses unique run and result names. Cleanup keeps the evidence. The suite coordinator finalizes each shard summary after checking the worker exit status. Never copy evidence into the repository.

Proof standards:

- Drive the athlete's path by tapping controls from launch onward. Setting `ShellModel` state, calling model methods, and unit tests are not UI proof.
- Capture the action and the resulting state. Take a `shot` before the tap and after the result, or use a proof whose attachment shows the end state.
- Check the side effect beside the pixels. Read what the action wrote in Debug, Records, or how many requests it sent in `fixture.modelRequestCount`.
- The fixture is the only mock, and it replaces services at the same seam as production, `AppServices`. Fixture mode gives the Coach fake model, credits, and intervals.icu clients, keeps records in a SwiftData store under `Application Support/fixture/` with CloudKit off, writes keys through `ICloudKeychainStore` with a file-backed `FixtureSecretStoreBacking`, and skips the StoreKit price lookup. A fixture run cannot prove live networking, the real keychain, iCloud sync, or StoreKit prices. Say so when a change touches them.
- Report the feature ID and the entry point with every artifact. Do not report a skipped entry point as verified through another one.

## Cleanup

Run `sim cleanup <run id>` when the run ends, and after every failed attempt before the next one. It shuts down and deletes `enduragent-verify-<run id>`, which removes the installed app and its data. It confirms the simulator is gone and lists the evidence it kept. Running it twice is safe.

Never run `simctl delete all`, `simctl shutdown all`, or `simctl erase`. Never quit Simulator.app or kill CoreSimulatorService, and never kill a process by name. The operator keeps their own simulators booted, and a parallel run owns its own. The selected build folder is a build cache, not evidence.

## Helpers

`sim` and `phone-check` are executables of the Swift package in `tools/`. They depend only on Apple frameworks and the package's own `ToolSupport` target. Every `sim` command prints what it did and exits non-zero on failure. `phone-check` runs the three operator-attended real-phone checks in [phone.md](phone.md), `choices`, `language` and `openrouter`, and refuses to start without an operator terminal.

| Command | Does |
| --- | --- |
| `doctor [<run id>]` | Read-only readiness check described in **Doctor** |
| `build` | XcodeGen, then `build-for-testing` into the selected build folder |
| `create <kebab-slug>` | New run id, evidence folder, and booted simulator |
| `install <run id>` | Installs the built app on the run's simulator |
| `launch <run id> [--keep] [app arguments]` | Kills and opens the app in fixture mode; `--keep` reuses the fixture state instead of wiping it |
| `shot <run id> <kebab-label>` | Screenshot to `<evidence>/<label>.png` |
| `test <run id> <proof>...` | UI proofs on the run's simulator, with attachments exported, in light appearance |
| `suite [<proof class>...] --shards <N> [--timings <json>]` | Build once, run owned simulator shards, clean up, and combine per-class results |
| `parity <run id> <prototype>-<state> <light\|dark> [--from <png>]` | Prototype capture beside a simulator screenshot |
| `cleanup <run id>` | Deletes the run's simulator and keeps the evidence |
| `shard <shard id> <proof class>...` | Internal: one suite worker that creates, installs, tests, reruns and cleans up its own simulator; `suite` starts it |

Run the helper tests with `swift test --package-path tools --filter SimTests`. They also run in `make test-tools`. The command tests use fake executables and never touch a simulator.

`ENDURAGENT_SIM_DEVICE` changes the device type. Parity comparisons assume the default iPhone 17e.

Keep the feature map honest as the app changes with `/maintain-verification-skill`.
