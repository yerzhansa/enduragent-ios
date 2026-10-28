# Verify on the real phone

Every check on this page needs the operator and a physical iPhone, except the simulator proof of the unhosted phone tests below. Simulator runs from the [verify-ios skill](./SKILL.md) never execute the phone checks.

## The phone tests drive the installed app

The `EnduragentPhoneTests` target has no target app: it sets no `TEST_TARGET_NAME`, depends on no app target, and the `EnduragentPhone` scheme builds no app. Every phone test launches the app already on the phone by its bundle id, so `xcodebuild test` installs nothing over the TestFlight or Debug build there. Install the build a step needs before the step: TestFlight for the TestFlight steps, the Debug build from Xcode for `closeout/debug-install` and after. The `phone-tests-unhosted` source rule keeps the project this way. The `EnduragentKeychainProof` scheme still builds `icu.enduragent.keychainproof`, but its test no longer installs it: install the built proof app with `xcrun devicectl device install app` before `TrainingKeychainDeviceProof` or `TwoPhoneReconnectCheck`.

### Prove it on the simulator

`EnduragentPhoneTests/PhoneUnhostedProof` proves on a simulator that this test bundle drives a separately installed app. It is not wrapped in `#if !targetEnvironment(simulator)`. Run it on its own simulator, never beside `CloseoutPhoneRun` or a `verify-ios` shard, because both install and drive `icu.enduragent.app`.

1. Build the Debug app with the marker build number in its own derived-data folder and install it: `xcodebuild build -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath /tmp/enduragent-dd/phone-unhosted-app CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION=9001`, then `xcrun simctl install "$SIM" /tmp/enduragent-dd/phone-unhosted-app/Build/Products/Debug-iphonesimulator/Enduragent.app`. Never build it in `/tmp/enduragent-dd/phone-unhosted`: when `Enduragent.app` sits in the products folder `xcodebuild test` uses, the test run installs that copy over the installed app as soon as `XCUIApplication(bundleIdentifier:)` launches it, and both copies carry `9001`.
2. Read `xcrun simctl appinfo "$SIM" icu.enduragent.app`. `CFBundleVersion` is `9001`. Record its `Path`. Every install, the reinstall a test run makes included, moves the app to a new folder under `Containers/Bundle/Application`, so `Path` changes even when the build number does not.
3. Run `test ! -e /tmp/enduragent-dd/phone-unhosted/Build/Products/Debug-iphonesimulator/Enduragent.app`. It must exit 0. Then run `testWritesAConversationInTheInstalledApp` alone: `xcodebuild test -project apps/ios/Enduragent.xcodeproj -scheme EnduragentPhone -configuration Debug -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath /tmp/enduragent-dd/phone-unhosted -only-testing:EnduragentPhoneTests/PhoneUnhostedProof/testWritesAConversationInTheInstalledApp CODE_SIGNING_ALLOWED=NO`. It launches the installed app with fresh fixture arguments, onboards, sends one message and reads the reply.
4. Read `xcrun simctl appinfo` again. `CFBundleVersion` is `9001` and `Path` is the one recorded in step 2. Any other `Path` means the test run reinstalled the app, and the proof fails even though both methods passed.
5. Repeat the `test ! -e` check from step 3, then run `testShowsTheConversationWrittenBeforeTheRun` alone the same way. It relaunches the app with `-EnduragentFixtureStore keep`, finds the message and reply the first run wrote, sends one more message and reads its reply.
6. Read `xcrun simctl appinfo` again. `CFBundleVersion` is still `9001` and `Path` is still the one recorded in step 2. Record the three `CFBundleVersion` and `Path` pairs and both result bundles in the review, then delete the simulator, `/tmp/enduragent-dd/phone-unhosted` and `/tmp/enduragent-dd/phone-unhosted-app`.

## The sitting

One sitting covers Milestones 4, 5 and 6. The step lists are data in `apps/ios/EnduragentPhoneTests/Sessions/`: `m4.json` (cap 40), `plan.json` (cap 30) and `closeout.json` (cap 50), one ledger each under `~/Library/Logs`. Each step names its driver and build, the message actions it plans, the setup the operator makes first, each check as where to look and the value that passes, and the state it ends with. `sitting.json` orders all 31 steps; `SittingOrder.problems` checks that every step appears once, that `closeout/fill` is first and `closeout/update` second, that no TestFlight step follows `closeout/debug-install`, and that `closeout/second-device-diagnostics` follows `closeout/two-phone`.

| Order | Steps | Driver and build | Messages |
| --- | --- | --- | --- |
| 1 | `closeout/fill` | operator, Milestone 5 TestFlight | 4 |
| 2 | `closeout/update` | operator, Milestone 6 TestFlight | 1 |
| 3 to 11 | `m4/list` to `m4/largest-text`, through `phone-check m4` | operator, Milestone 6 TestFlight | 15 |
| 12 to 18 | `plan/1` to `plan/7`, through `phone-check plan` | runner `PlanPhoneRun`, Milestone 6 TestFlight | 13 |
| 19 | `closeout/about` | runner `CloseoutPhoneRun` | 0 |
| 20 | `closeout/diagnostics` | operator | 0 |
| 21 | `closeout/feedback` | runner `CloseoutPhoneRun` | 0 |
| 22 | `closeout/language` | runner `CloseoutPhoneRun` | 4 |
| 23 | `closeout/choices` | runner `ChoicesInConversationCheck` | 12 |
| 24 | `closeout/openrouter-signin` | operator | 2 |
| 25 | `closeout/lifecycle` | operator | 4 |
| 26 | `closeout/reads` | operator | 3 |
| 27 | `closeout/debug-install` | the operator installs the Debug build | 0 |
| 28 | `closeout/openrouter-recovery` | runner `OpenRouterRecoveryPhoneCheck`, Debug | 2 |
| 29 | `closeout/keychain-proof` | runner `TrainingKeychainDeviceProof`, Debug | 0 |
| 30 | `closeout/two-phone` | runner `TwoPhoneReconnectCheck`, Debug | 0 |
| 31 | `closeout/second-device-diagnostics` | operator, Debug on the second device | 0 |

Milestone 4 plans 15 of 40, Milestone 5 13 of 30 and Milestone 6 32 of 50. Every `phone-check` command asks for each invocation's budget and refuses, through `PhoneBudget.approve`, an answer that is not a whole number, a budget below the chosen steps' planned count, and one that would pass the session's cap after what its ledger already spent.

### Run phone-check m4

The Milestone 4 steps are operator steps on the installed TestFlight build. Supply the first and last step by position in `m4.json`, from 1 (`m4/list`) to 9 (`m4/largest-text`), and a new local evidence folder:

```sh
swift run --quiet --package-path tools phone-check m4 "$FIRST_STEP" "$LAST_STEP" "$M4_RUN"
```

It prints each chosen step's setup, checks and end state, asks the budget, and books the whole budget in `~/Library/Logs/enduragent-m4/PHONE/messages.tsv` before the operator taps. After each step it asks the verdict, `pass`, `fail <check>` or `blocked <reason>`, writes it to `verdicts.tsv` in the folder, and stops at the first that is not `pass`.

## Run PhoneRun

This is the saved procedure for the 2026-10-01 run on build `2bbe2ee`. The phone runner lives in `apps/ios/EnduragentPhoneTests/PhoneRun.swift`. Only the `EnduragentPhone` scheme includes that target. The Swift file also compiles out on simulators. The normal `Enduragent` scheme and `sim` never execute it, and it uses no `XCTSkip`.

Before **every** invocation, ask the operator for that invocation's message budget. Explain that live Send and Try again actions spend Credits or use the connected OpenRouter account. Each Send or Try again consumes one budget slot. The full procedure needs seven Sends and two Try again taps, so its minimum is nine slots. New conversation can also save memory through the model. Do not infer a new budget from a previous run. If a run fails or stops, report the actions already taken and ask for a new budget before another invocation.

Ask the operator to provide the connected, unlocked iPhone and approve the single calendar Add for this run. Never enter a passcode, password, API key, or any other credential. Never accept a consent, terms, or login screen. Never tap purchases, sign out, disconnect intervals.icu, delete the app, or erase its data. Never send or tap Try again beyond the approved budget. The runner refuses a missing budget before launch, checks the budget before every message action, and permits one Add only.

1. Run the command below against the build already installed on the phone; it builds only the test bundle and installs nothing over the app. The device identifier is an argument supplied for this run, never a committed value. Keep build products under `/tmp` and logs and result bundles outside the tree.
2. Launch plainly, with no fixture arguments and no launch environment. Capture the first screen. If the phone is locked or shows consent, terms, login, onboarding, or any system alert, stop without tapping it. The operator handles the screen. The runner fails with `PhoneRunBlocked`, preserves its attachments, and sends no message. Ask for a fresh budget before restarting.
3. On the conversation screen, check the earlier conversation, open History and a read-only archived conversation, and record Credits before the run.
4. Send `What should I focus on in training this week?`. Capture partial text while working and the settled reply.
5. Send the eight-week base-training question in the script. Stop during partial text, check the dimmed partial reply, notice, and Try again, then tap Try again once. A missed Stop is a failed proof. Do not resend without another budget.
6. Send the short tempo-ride question, press Home for twenty seconds, and return. Check the complete reply and the finished-while-locked line. The 2026-10-01 run pressed Home; it did not lock the phone. An actual lock and unlock is an operator action.
7. Send the 100 km pacing question, terminate during partial text, and relaunch plainly. Check the interrupted turn and Try again, then tap Try again once. Partial text lost on a hard kill is accepted for Milestone 2.
8. Request one 45-minute endurance ride for tomorrow. Capture the review and tap Add exactly once. Capture the Done line. The operator checks intervals.icu for exactly one matching event on that date. The UI's Done line alone cannot prove the server count. Do not repeat Add if its outcome is uncertain.
9. Request one recovery spin for the day after tomorrow. Cancel once and relaunch. Check that the review stays gone.
10. Start New conversation with the compose icon in the top bar, check the composer, send the warm-up question, and open the previous conversation in History. Record Credits afterward and leave the app in the foreground. The 2026-10-01 run did not exercise a second device or purchases.

Run only after the operator has answered the budget question. Supply `DEVICE_ID`, `MESSAGE_BUDGET`, and a new `PHONE_RUN` evidence folder in the shell:

```sh
xcodegen generate --spec apps/ios/project.yml
caffeinate -i xcodebuild test -project apps/ios/Enduragent.xcodeproj -scheme EnduragentPhone -configuration Debug -sdk iphoneos -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath /tmp/enduragent-dd/VSKILL-phone -parallel-testing-enabled NO -resultBundlePath "$PHONE_RUN/phone.xcresult" -only-testing:EnduragentPhoneTests/PhoneRun ENDURAGENT_PHONE_MESSAGE_BUDGET="$MESSAGE_BUDGET" > "$PHONE_RUN/phone.log" 2>&1
```

The runner checks English questions exactly and requires existing conversation and History data, matching the original upgrade run. The operator selects the language and handles any preconditions on the phone. Export attachments from the result bundle and inspect the screenshots. Report messages, Try again taps, Add taps, Credits before and after, the calendar event, any failed step, and the state left on the phone. Attachments can contain private conversations or the Home screen; keep them in the operator's local evidence folder.

## Prove the OpenRouter HTTPS callback and cancellation

`EnduragentPhoneTests/OpenRouterSignInPhoneCheck` proves OpenRouter sign-in on a signed phone. It stays pending until the operator runs it. Controlled app completions do not prove the installed phone's associated-domain handoff. No simulator proof is owed while the domain is unconfigured.

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

## Prove OpenRouter recovery, selected model, sync and phone lock

`EnduragentPhoneTests/OpenRouterRecoveryPhoneCheck` and the `phone-check openrouter` command prove OpenRouter recovery on a signed phone. Every step stays pending until the operator's signed-phone session. Simulator proofs are `OpenRouterRecoveryProof` and `OpenRouterAccessProof`. The phone procedure reuses `OpenRouterSignInPhoneCheck` for the actual callback, which remains its primary owner.

Use the signed plain install, English, two updated iPhones on the same Apple ID, iCloud Keychain enabled, a working intervals.icu connection and an OpenRouter account with usable funds. The operator configures and verifies the associated domain as above. Do not put a key, code, verifier or athlete ID in launch arguments. Nothing in this procedure runs while the operator is away.

Before every invocation the interactive helper asks for a fresh message budget and explicit acknowledgement of automatic usage charges. It refuses a non-interactive terminal and an insufficient budget before build, launch or Send. Every Send consumes one slot. The planned minimum is zero for sign-in, model picking, cancel, recovery and second-phone consent, and one for each tool, revoked-key or locked-turn step. No Try again, New conversation, purchase or calendar Add. A failed invocation stops, records its Sends and phone state, and requires a fresh budget before another run.

At every OpenRouter page automation stops all interaction. The operator handles the system permission alert, verifies `openrouter.ai` and Enduragent, and signs in, approves, cancels or revokes by hand. XCTest captures the page and waits at most 180 seconds for the operator's action. It enters no credentials and taps nothing in the browser. Never treat a missing callback, cancellation, sync or lock screenshot as a pass.

Run one step at a time, with a new local evidence folder each time:

```sh
swift run --quiet --package-path tools phone-check openrouter <step> <device id> <new local evidence folder>
```

1. `signin` runs the existing HTTPS callback proof from Credits and saves the OpenRouter choice without a Send. Inspect the signed-domain handoff and retained conversation. Separately run the existing previous-access cancellation proof above once from Credits and once from OpenRouter with its own budget for each.
2. `pick` asks for a catalog model ID, its display name and its hosting provider, with zero Sends. It taps the named Settings row, captures any provider disclosure and waits for the operator to read and accept it by hand. The model stays marked after relaunch and Debug shows the saved ID. Then `tool` asks for that exact saved ID and a fresh one-Send budget. The response must stream and include an intervals.icu tool call, exposed by `chat.toolProgress`, and finish without a notice. Inspect the response, earlier messages, OpenRouter usage and unchanged Credits.
3. `revoked` asks the operator to revoke the current test key by hand on OpenRouter, then sends one message. It must show one status-owned Sign in again action, retain the message and keep the recovery prompt after relaunch. It must make no automatic or Credits request. Check the OpenRouter dashboard and Credits manually.
4. `cancel` taps Sign in again once, stops at the OpenRouter page and waits for the operator to cancel the system sheet. The rejected-key prompt and conversation stay. It sends nothing.
5. `recover` taps Sign in again once and stops at the page for the operator to sign in and approve. The prompt disappears, the saved model stays, and the conversation survives relaunch. Run `tool` again with a fresh one-message budget and verify a streamed tool-backed turn in the same conversation.
6. On the second updated phone, `second-consent` requires its first disclosure of the synced choice. Supply the source phone's exact model display name and named provider. The disclosure must name OpenRouter, that model and that provider before any request. Decline and relaunch must still require consent. The operator accepts by hand, then runs `tool` on the receiver with a fresh budget and the source model ID. Verify the saved selection/model and actual successful use of the synced key. A mock or one-phone result cannot close this gate.
7. `locked` needs a fresh one-message budget and the selected model ID. Start the turn while unlocked, then physically lock the phone while the turn is working. Keep it locked until coaching finishes, then unlock. Inspect `operator-locked-phone`, the completed reply and tool evidence after unlocking. Home or temporary inactivity does not prove locked Keychain access. Leave this gate pending unless the screenshot and the operator's observation prove an actual lock during the turn.

The helper saves the approval, xcodebuild log, result summary, screenshots, accessibility transcripts and operator verdict locally. Check exactly one test passed with no skip and inspect every attachment. Its build products stay under `/tmp/enduragent-dd/U8-3-phone` and are removed after the run. Report signed builds, domain setup, both devices' update/sync state, selected model/provider, Sends used and remaining budget, failed step and state left on each phone. Live model picking, real revocation, two-phone sync and locked-phone use remain open completion gates until these steps pass.

## Prove native training persistence on one phone

The `EnduragentKeychainProof` scheme and `EnduragentPhoneTests/TrainingKeychainDeviceProof` are a device-only proof. It pairs native `ICloudKeychainStore` with the existing fake model, Credits and intervals.icu ports. It proves native persistence, not live service authentication or two-device synchronization. Keep criteria 1 and 4 and the timing evidence pending until the operator runs it.

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

## Prove reconnect across two phones

`EnduragentPhoneTests/TwoPhoneReconnectCheck` runs in the isolated `EnduragentKeychainProof` build. Run it only with the operator present and two updated physical iPhones on the same Apple ID with iCloud Keychain enabled. This check stays pending until the operator runs it. Use synthetic proof credentials and fake services. Zero live messages and no billed service are used.

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

## Prove live French replies after choosing a language

`EnduragentPhoneTests/LanguageReplyCheck` and the `phone-check language` command prove live replies in the chosen language. The check stays pending for the operator's real-phone session. The helper requires an interactive terminal and asks for this invocation's message budget before building, launching or sending. Explain that four live Sends spend Credits or use the connected OpenRouter account. A failed invocation needs a new budget. Nothing in the simulator procedure runs this check.

Prepare the unlocked phone with working model access, consent accepted, no composer draft and no open turn or workout review. In iPhone Settings, arrange the preferred languages as Russian, French, English. French must be the first supported language. The operator handles every credential, consent and system alert. Use a plain Debug app launch without fixture arguments or language overrides.

1. Open Settings > Language and choose Français. Capture the selected row, close the sheet and return to the conversation.
2. Terminate and relaunch without deleting data. Before Send, require the French composer placeholder and reopen Settings > Language to capture Français selected.
3. Send `What is an endurance ride?`. Capture the entire settled reply and its accessibility transcript. Require French generated prose, with no failed-turn notice or Try again.
4. Choose Automatic through Settings > Language. Terminate and relaunch again. Require French chrome and Automatique selected before the next turn.
5. Send `What is a recovery ride?`, `テンポ走とは何ですか？` and `/review`, one at a time after settlement. Capture every reply. All three must use French generated prose regardless of message language.
6. Inspect every reply page and transcript before recording `pass`. Report the actual Sends, remaining budget, any failed step and the state left on the phone. The runner leaves Automatic selected and never taps Try again, New conversation or calendar Add.

Supply the connected phone identifier and a new local evidence folder. Keep screenshots and transcripts local because they can include private conversations. Build products go to `/tmp/enduragent-dd/U9-2-phone`.

```sh
swift run --quiet --package-path tools phone-check language "$DEVICE_ID" "$LANGUAGE_RUN"
```

The physical-device `EnduragentPhone` scheme includes this proof, which compiles out on simulators. Passing its capture test supplies the stored selection, relaunch and reply evidence. The operator's recorded prose verdict supplies the live-language judgment. Scripted fixture reply text cannot replace that verdict.

## No system banner or notification

Every reply runs on plain background time from `UIApplication.beginBackgroundTask`. iOS shows no banner or progress interface for it. The app posts no notification and never asks for notification permission. The `no_system_banners` SwiftLint rule rejects `BGContinuedProcessingTask`, `BGTaskScheduler`, and `UNUserNotificationCenter` in `apps/ios`. Either surface needs an operator decision before it returns.

A simulator cannot prove that no banner appears. Run this check only with the operator present on a physical iPhone. Fixture mode otherwise uses `ImmediateExecutionHost`, which never asks iOS for background time. The launch argument `-EnduragentFixtureHost background-time` selects the live build's `BackgroundTimeHost` with `UIApplication` background time. It keeps the scripted model, fake Credits and intervals.icu, fixture secrets and records, so the scripted model spends no Credits.

Install a signed Debug build, then launch it without a test runner or debugger. An attached XCUITest runner or debugger may keep iOS from suspending the app, so iOS may never end its background time. XCUITest also terminates an app it launched when the test ends, which settles the turn as `processEnded`. To script the lock, launch with the command below, then run a test that only calls `XCUIApplication(bundleIdentifier:).activate()`, sends, presses the lock button, and ends. Supply the connected phone identifier. Keep screenshots in a new local phone evidence folder.

The `--` stops `devicectl` from reading the app's arguments as its own options.

```sh
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing -- icu.enduragent.app -EnduragentFixture first-week -EnduragentFixtureStore fresh -EnduragentFixtureHost background-time -AppleLanguages '(en)' -AppleLocale en_US
```

While the phone is locked, `xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier icu.enduragent.app --source "Library/Application Support" --destination <folder>` copies the records. Keep only the `fixture/` stores. Delete any copied `EnduragentCoach/` store and `secrets.json` without reading them.

Complete fixture onboarding and consent. For every relaunch, use the same command with `-EnduragentFixtureStore keep`. Record the OS, build, and language. Settings > Debug shows no Expire current lease button with this host. If the button appears, the launch used `ImmediateExecutionHost` and proves nothing about background time.

| One action | One observation |
| --- | --- |
| Send `fixture:slow`, then press Home. | No banner or progress interface over the Home Screen. |
| Lock during `fixture:slow`, then unlock. | No notification on the Lock Screen or in Notification Center. |
| Send `fixture:memory-until-system-interruption`, check the saved memory in Settings > Debug > Records, then lock until iOS ends the background time. | Reopen shows the interrupted reply with saved memory retained. Records shows `interrupted graceEnded`. |

`fixture:memory-until-system-interruption` saves fixture memory, then sends a model heartbeat every ten seconds so the reply watchdog does not settle it first. It does not extend background time or synthesize expiry. Record that iOS caused the expiry. On 2026-10-16 on an iPhone 12 Pro Max with iOS 26.2.1, Home showed no banner for an ordinary reply or `fixture:slow`. A memory turn locked at 21:01:52 settled `interrupted graceEnded` with one saved memory section before 21:02:54, while the phone was still locked.

## ChoicesInConversationCheck

The `phone-check choices` command and `EnduragentPhoneTests/ChoicesInConversationCheck` are a separate proof. Run it only with the operator present. It proposes twelve live messages across six cases. Each invocation sends one message and asks for its own message budget before launch or Send. A fresh conversation can also spend Credits saving memory. The operator approves that memory work with the invocation's budget. It stays pending while the operator is away.

Use the phone's own Credits, the live built-in model, English, and a plain launch. The operator selects Credits and handles consent, credentials, onboarding, or system alerts before the run. The helper records the model ID from the built app's `OpenRouterModel` value. It uses only the physical-device `EnduragentPhone` scheme, and the capture test compiles out on simulators. It never approves a workout review. The messages include synthetic medical symptoms and remain in the phone's conversation records.

Supply the connected phone's identifier and a new local evidence folder. The helper keeps build products under `/tmp/enduragent-dd/U11-1-phone`.

```sh
swift run --quiet --package-path tools phone-check choices "$DEVICE_ID" "$CHOICES_RUN"
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

This is the pending live proof for criteria 1 to 3 and 5. Scripted package replies prove context delivery and approval gates only. `ChoicesInConversationTests` proves that `/start` through `Coach.send` starts a new conversation after an unanswered offer, and that answering a numbered choice while a plan-save card waits saves no plan and leaves the card waiting. `ReviewCommitTests.aWaitingReviewHasNoTimerAndIsApprovedAfterElevenMinutesAndAnUnrelatedTurn` and `ReviewApprovalTests.approvalAfterAnotherTurnRunsTheSavedReviewWithNoModelRequest` prove that a waiting workout review stays pending through an unrelated turn until its separate approval. No simulator run supplies the live-model evidence.

## Run PlanPhoneRun

`phone-check plan` and `EnduragentPhoneTests/PlanPhoneRun/testPlanPhoneRun` are Milestone 5's plan phone session on the operator's real iPhone: 12 Sends and one New conversation, which also saves memory, under a cap of 30 message actions for the whole milestone. Only the operator runs it. An agent never runs `phone-check plan`, `PlanPhoneRun` or any of its steps, and nothing in the simulator procedure covers it. `PlanPhoneRun` compiles out on simulators, and only the `EnduragentPhone` scheme includes it.

Each Send, Try again and New conversation is one message action. They spend the phone's Credits or its OpenRouter account. The seven steps `plan/1` to `plan/7` plan 2, 1, 2, 2, 3, 1 and 2 actions, 13 in all, under a cap of 30; both live in `apps/ios/EnduragentPhoneTests/Sessions/plan.json`. `phone-check plan` keeps the milestone's count in `~/Library/Logs/enduragent-m5/PHONE/messages.tsv`, one row per invocation under the header `steps`, `budget`, `spent`. Before build or launch it asks for this invocation's budget and refuses:

- a budget below the planned count of the chosen steps;
- a budget that would take the milestone past the cap of 30;
- a `messages.tsv` header or row it cannot read;
- a step range that mixes `plan/6` with other steps.

It records the whole budget as spent before launch. After the run it replaces that row's count with the `Message action` lines in the runner's `plan-phone-actions` attachment, or keeps the whole budget when it cannot read them. It passes each chosen step with its planned count from `plan.json` in `ENDURAGENT_PLAN_PHONE_STEPS`, as `plan/1=2,plan/2=1`, and `PlanPhoneRun` runs exactly those steps and plans exactly those counts. The runner refuses before launch when that variable cannot be read, or when `ENDURAGENT_PHONE_MESSAGE_BUDGET` is missing or below the planned count, and throws `PhoneRunBlocked` before any message action that would pass the budget. A turn that ends with Try again is retried only while the budget allows.

The runner launches plainly and stops if a plan-save card or workout review is already open. Each step starts from the conversation the step before left:

1. `/plan` from the slash list gets a question back. The details message calls `build_plan_skeleton` and `get_sample_week`. No card appears. The phone starts with no saved plan and no plan-save card.
2. `Can I get from 250 to 300 W?` calls `assess_feasibility`. No card appears.
3. `Save that plan` shows card A with no replaces line. It still waits after a kill. Save plan makes it read Saved, which survives a second kill. The answer to `What is my current plan?` names A.
4. `Make it 10 weeks and save it` shows card B replacing A, and Save plan saves it. The answer to `When did my plan change?` names A and B.
5. A workout review waits. `Make the plan 12 weeks`, then `Save that plan`, shows a card replacing B. It still waits at 580 seconds and reads Expired with no Save plan or Cancel before 615 seconds. Then the session's one calendar Approve is tapped once. Set Auto-Lock to Never: the step keeps the app in the foreground for eleven minutes.
6. Turn on the largest text size and VoiceOver in iOS Settings, and turn them off after the step. `Make the plan 14 weeks and save it` shows a card whose parts read in order, with the bar in the transcript under the card. Save plan saves C. This step runs in its own invocation.
7. `Make the plan 16 weeks and save it` shows a card. New conversation shows it once at the top, marked Prepared earlier. Cancel makes it read Canceled with no controls.

The operator prepares the unlocked phone in English on the seeded test account, with no draft, and types `ready` when the helper asks. Supply the first and last step, the connected phone's identifier and a new local evidence folder. The helper keeps build products under `/tmp/enduragent-dd/M5-8-2-phone` and removes them after the run. A run that stops can resume at the failed step in a new invocation with a new budget.

```sh
make project
swift run --quiet --package-path tools phone-check plan "$FIRST_STEP" "$LAST_STEP" "$DEVICE_ID" "$PLAN_PHONE_RUN"
```

The folder keeps `approval.json`, `phone.log`, `phone.xcresult`, `summary.json`, the exported `attachments` and `verdict.txt`. Inspect every screenshot and the actions log before typing `pass`. After step 5, check that the intervals.icu website shows exactly one new workout. After step 6, confirm that VoiceOver read the card's title, name, goal, length, each phase and the replaces line before Save plan and Cancel. Report the steps run, the message actions spent, the milestone total, any failed check and the state left on the phone.
