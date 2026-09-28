M1-12 review fixes
=================

The worktree started clean on `m1/12-session-settings` at `00422479806eb4d5ea179f978ba015493cd15dd9`. A fresh fetch confirmed the same SHA on `origin/m1/12-session-settings`. The implementation under test is `2c12fd95a97ada24d91a2584900560998af03bd4`. The delivery commit adds this evidence and the mutation patches.

All requested findings are fixed. The optional synced-preference change remains a follow-up under the scope the operator specified.

| Finding | Fix and permanent regression | Before at `0042247` | After |
| --- | --- | --- | --- |
| 1. Lost late reply | `AutomaticReset` uses turn membership without a row-ULID filter. `staleResetPreservesAnOlderTurnsReplyAfterTheTriggerWasAccepted` checks History, the stale-reset job, and the memory-flush request. | Failed: the older reply was missing from the job and appeared zero times in the flush request. | Pass: both rows are saved, the reply appears once, and the triggering question is excluded. |
| 2. Idle expiry during daily grace | `SessionFreshness` checks idle before returning deferred daily reset. `idleExpiryStillResetsDuringDailyGrace`. | Failed: no idle reset and no archived conversation. | Pass: a five-minute idle rule resets the 03:50 to 04:10 exchange. |
| 3. DST | Reset hours use `Calendar.date(bySettingHour:minute:second:of:)` and calendar day arithmetic in the athlete's zone. `springDSTResetStillOccursAtFourLocal` and `autumnDSTDoesNotResetAnHourEarly`. | Both failed: spring reset was late and autumn reset was early. | Both pass through Coach send, snapshot, and History. |
| 4. Confirmation language | `ShellModel` stores the catalog key and variables; `confirmLine` renders through the current phrasebook. `visibleConfirmationChangesWithTheLanguagePreference`. | The original expired-confirmation probe failed. The permanent test also fails for executed confirmation, including its summary variable, on the base shell. | Both expired and executed cases pass after English-to-Spanish selection. |
| 5. Completion notification language | `DrainLease` retains the lease without retaining its start language. It resolves the current language when finishing. `completionTitleFollowsAChoiceMadeDuringTheReply`. | Failed: notification title was `Coach` instead of `Entrenador`. | Pass: the notice is Spanish, its reply excerpt is preserved, and the task title remains the original English title. |
| 6. First render after relaunch | `AppLaunch.open` awaits the existing `ShellModel.refreshStatus` before returning a ready shell. The app displays a progress indicator during launch. `relaunchDoesNotRenderAutomaticOverASavedFixedPreference`. | Failed: Spanish saved on an English phone initially produced `Message your coach`. | Pass: the first ready model produces `Escribe a tu entrenador`, before `appear()`. |
| 7. Automatic replies | The preference resolves both text and replies through `appLanguage(device:)`. Reply-language resolution no longer accepts message text. Renamed the owner's test to `automaticPreferenceRepliesInThePhoneLanguage`. | English-phone/Italian-question and French-phone/English-question cases failed, including the instruction to mirror the question. | Both pass with an explicit phone-language instruction. The fixed-choice integration test also passes. |
| 8. Coverage gaps | Added `automaticAppTextFollowsANonEnglishPhone` for Spanish and French phones and hour `24` to `eachFieldRejectsItsInvalidValue`. | Both additions pass against the correct original code. The independent review established that M02 and M03 previously survived. | Both mutants are now killed by the new assertions. |

Automatic replies now follow the iPhone's language. This reverses the owner's earlier deliberate choice to mirror the question because ADR-0080 says Automatic follows the iPhone, and `CONTEXT.md` defines one preference controlling both app text and coach replies. The active Automatic save-failure catalog text was updated to describe that contract, and the generated catalog was refreshed.

The first full failing run used unchanged production code at `0042247`, the new package regressions, and the review's original shell probes compiled with byte-identical copies of the production shell and draft store. It ran 601 tests in 87 suites and failed with 19 intended issues. `baseline-0042247.log` records those failures. The new package regressions then passed in `package-after.log`, 599 tests in 86 suites.

The permanent shell tests live in `apps/ios/EnduragentTests/ShellLanguageTests.swift`. `pnpm test:swift` now runs them on macOS as well as the coach package. `tools/test-shell.mjs` copies `ShellModel.swift`, `DraftStore.swift`, and `AppLaunch.swift` unchanged into an ignored temporary package. It substitutes only app host adapters and removes the test file's app-module import. The tests use a real Coach with fake ports and create the proposal by sending a scripted tool request. This replaces the old source-text assertion with executed behavior checks.

`shell-before-0042247.log` records three failing assertions from the permanent tests using base app sources. That additional run uses the current Coach dependency; the original full baseline above establishes the failures with the base Coach too. `shell-after.log` records both test functions passing, including three test cases.

| Mutant | Change | Full-suite result | Killing tests |
| --- | --- | --- | --- |
| `M02.patch` | Automatic app text always English | KILLED, exit 1 | `automaticAppTextFollowsANonEnglishPhone`, `automaticPreferenceRepliesInThePhoneLanguage` |
| `M03.patch` | Accept daily hour 24 | KILLED, exit 1 | `eachFieldRejectsItsInvalidValue`, specifically hour 24 |
| `M-row-filter.patch` | Restore the row-ULID filter | KILLED, exit 1 | `staleResetPreservesAnOlderTurnsReplyAfterTheTriggerWasAccepted` |
| `M-fixed-offset.patch` | Restore midnight plus elapsed seconds | KILLED, exit 1 | Both spring and autumn DST regressions |
| `M-idle-grace.patch` | Return daily deferral before checking idle | KILLED, exit 1 | `idleExpiryStillResetsDuringDailyGrace` |

Every mutant compiled and ran the full 599-test coach suite and the two shell test functions. `.review/run-mutants.py` applied each patch, ran `pnpm test:swift --disable-sandbox`, reversed it with `git apply -R`, and verified SHA-256 equality for every affected source file. The shell suite ran even when the coach suite failed. M02 and M03 are unchanged copies of the independent review's patches. The fifth mutant was added in this correction cycle. `.review/.gitattributes` treats patch context whitespace as patch data; it does not change source checks.

| Gate | Result | Evidence |
| --- | --- | --- |
| Catalogs | PASS | `catalogs.log`: 2437 leaves, 2473 keys, 17 locales; generated files match. |
| Source | PASS | `source.log`: 21 guard tests and no source violations. |
| SwiftLint | PASS | `lint.log`, `pnpm lint:swift --no-cache`. |
| Format | PASS | `format.log`, `pnpm check:format`. |
| Lint baseline | PASS | `lint-baseline.log`: 43 entries at `origin/milestone/m1`, 40 now, none added. Base SHA `e915236a4d81e9616915f3f76a717afe1e92a921`. |
| Full Swift run 1 | PASS | `swift-1.log`: 599 coach tests in 86 suites plus two shell tests in one suite. |
| Full Swift run 2 | PASS | `swift-2.log`: the same suites pass. |
| Full Swift run 3 | PASS | `swift-3.log`: both suites pass after all mutation patches were reversed. |
| README XcodeGen | PASS | `xcodegen.log`. The generated project includes the new app tests. |
| README Xcode build | PASS | `xcodebuild.log`, generic iOS Simulator SDK destination, signing disabled. |
| Test-bundle build | PASS | `test-bundle-build.log`, `build-for-testing` with the same project, scheme, SDK, destination, and signing setting. |

The first Xcode build exited 74 because nested SwiftPM sandboxing failed with `sandbox_apply: Operation not permitted`. `xcodebuild-sandbox.log` preserves it. Both successful Xcode builds ran outside that sandbox. They only compiled; no simulator was booted or used. All long local runs used `caffeinate`. Swift runs used a writable Clang module cache and `--disable-sandbox`, with `OPENROUTER_API_KEY` and `INTERVALS_API_KEY` unset. The opt-in tests `streamsOneTurn`, `readsSevenDays`, and `appAccountTokenIsStableOnSecItem` remained skipped.

Logs, `gates.tsv`, and the required `mutants.tsv` are in `/Users/yerzhansagyt/Library/Logs/enduragent-m1/m1-12/review-fix/`.

The owner must rerun these simulator lanes on the delivered head:

- The hosted `ShellLanguageTests`, session, launch, credential, and lease tests, plus `LanguagePickerProof`. Include Automatic on a non-English phone, saved Spanish on an English phone with inspection of the first chat frame, and visible expired/executed confirmations while changing language.
- `DailyResetProof` and `IdleResetProof`, including both Amsterdam DST dates and the five-minute idle rule spanning 03:50 to 04:10. Check the notice and archived conversation.
- `SessionRejectionProof`, including hour 24, and `RatioAppliesProof`.
- `FinishedWhileAwayProof` and `LeaseReportProof`, with a language change while the reply is running. Check that the posted notification uses the new language and the existing task title retains its original language.
- `QueuedTurnAfterKillProof`, `RelaunchKeepsChatProof`, `ConfirmedPreviewProof`, and `ConfirmedPreviewDarkProof`. Include a queued retry whose older turn's reply settled after the reset boundary, and verify both History and extracted memory.

Synced preference refresh remains a follow-up. `RecordLog.imports` exposes remote-store arrivals and `Ledger.imports` forwards them, but no production code consumes that stream. Coach's preference cache therefore has no existing arrival callback where a one-line invalidation can be added. Fixing it requires introducing observation and managing its lifetime. No observer or second preference writer was added in this task.

The implementation commits are `dcf0a20` for reset behavior and the hour-24 test, `dd46dc9` for preference resolution and notification language, and `2c12fd9` for shell rendering and its executable regressions. All files were staged by name. No PR was created.
