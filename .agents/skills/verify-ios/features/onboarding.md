# Onboarding and connection

The athlete accepts the health notice, connects intervals.icu or skips it, receives starter Credits, agrees to sharing with the AI providers, and enters the one ongoing conversation. A kept store without current consent opens the same consent screen before chat. Settings > intervals.icu provides replacement and confirmed disconnect.

## Sub-features

- `onboarding-notice` shows the health notice with `notice.continue`.
- `onboarding-connect` saves a non-blank key and shows `connect.saved` separately from profile or wellness guidance in `connect.notice`. `connect.displayAction` opens the empty masked field after rejection or retries unavailable display data with the saved connection. Available identity and wellness values stay visible, missing values have no row, and `connect.continue` works after a saved key even when its display failed.
- `onboarding-connect-empty` keeps the connect screen and shows `Enter an intervals.icu API key.` for a first connection and the current-connection sentence for a replacement in `connect.saved`. A first failed save says `The connection wasn't saved. Try again.` and offers another Connect or Skip. A replacement keeps the previous-connection sentence.
- `onboarding-skip` clears the typed key and edit state before opening starter Credits without a training connection. Later Settings opens on Connect and its field is empty, including after a late onboarding binding write. The conversation welcome lists the supported commands whether or not intervals.icu is connected. `fixture:training-data` reads the profile and calendar and explains their absence. Connecting through Settings preserves that turn and lets the next request read the key owner's data.
- `training-key-keyboard` uses one masked key field in onboarding and Settings, with autocorrection and capitalization disabled and an ASCII-capable keyboard. The connect-later proof launches with `ru,fr,en`, types two ASCII characters in the onboarding field, skips setup in French, then checks the Connect row and empty field before typing the key in Settings.
- `onboarding-starter` is the Credits screen, titled Credits. `starter.progress` shows while the starter grant is requested. Then `starter.credits` shows the starter result, such as `Added 200 credits`, above `starter.start`, Start chatting, which is the only button. A failed grant shows its catalog sentence instead of stale grant success, and Start chatting still opens the conversation.
- `onboarding-consent` names OpenRouter, the built-in model, its receiving provider, and the data shared. Consent is local to this iPhone and applies to the disclosed recipient. A legacy agreement and another device's agreement cannot authorize a new provider. `consent.accept` saves permission and opens chat. `consent.decline` keeps chat locked and shows the same disclosure with `consent.resume` labeled Agree and continue. One tap saves permission and opens chat without repeating the choice or requesting starter Credits. Relaunching before agreement asks again.
- `onboarding-credentials` is now proved by the [Settings connection proofs](./settings.md). Settings keeps the current connection after a blank replacement, Cancel, or a failed keychain write. A different athlete requires Switch athlete while work or a workout review is pending. A replacement for the same athlete keeps the review usable.
- `onboarding-unavailable` shows `launch.storageUnavailable` when the record store cannot open. A locked keychain on a kept store preserves the transcript and shows `chat.composer.notice`.

## How to get to it (user POV)

- Open the app with a fresh store and choose Continue.
- Enter an intervals.icu key and choose Connect, or choose Skip for now.
- Choose Continue after connection, or Skip for now. On the Credits screen, read the starter result, then choose Start chatting.
- Read Your coach uses AI, then choose Agree and continue or Not now. After Not now, tap Agree and continue once to open chat. A saved turn refused for missing consent stays unchanged after agreement until the athlete taps Try again.
- From the conversation, choose Settings > intervals.icu. Choose Replace key, enter the masked value and save. Known owner changes and Disconnect need explicit confirmation. Debug holds only credential fault controls.
- Buy Credits under the no-Credits notice opens the Credits screen above the conversation; Back returns to the existing conversation.

## Driving it with sim and XCUITest

Preconditions:

- Follow the [index](./README.md) setup and require a passing doctor. Each proof prepares its own fixture state unless it needs an upgrade store.
- The fixture athlete is Ada Kovač, `i1001`, with Fitness 42, Fatigue 49, and Form -7 on 1998-06-15.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim test <run id> ConnectIntervalsProof` | Blank and failed saves, saved profile rejection, rejected profile request, temporary profile failure, wellness rejection and outage, no wellness and missing values, then correction or retry. Attachments start with `onboarding-` and end with `light`. Skip and later Settings connection with a Russian-first language list produce `skipped-training-data-unavailable`, `settings-latin-key-saved`, and `connected-later-conversation-kept`, with the same suffix. |
| `sim test <run id> AccessOnboardingProof` | The Credits screen reads `200 credits` above Start chatting, its only button, with no OpenRouter text and no text field; the conversation answers after a relaunch, `access-onboarding-starter-credits`. Unavailable reads, failed provisioning, an already used grant and a failed credential write each show their sentence on the same screen, and Start chatting still opens the conversation, `access-onboarding-unavailable`, `access-onboarding-provisioning`, `access-onboarding-already-granted` and `access-onboarding-credential-write`. A saved build 9 OpenRouter choice shows the same screen, gets a reply on Credits, and Settings shows Credits with no Access method row and no Model row, `access-onboarding-build9-openrouter-settings`. |
| `sim test <run id> StarterCreditsProof` | `starter.credits` and `starter.start`, `03-starter-credits`. `testDebugStarterUsesInjectedDeviceCheck` claims the starter grant from Settings > Debug > Credits and reads `200 credits`, `debug-starter-credits`. |
| `sim test <run id> ProviderConsentProof` | Consent before chat, decline without opening chat, consent on relaunch, a deferred consent screen without starter Credits, and one saved consent after one Agree tap, `provider-consent`, `provider-consent-deferred`, and `provider-consent-deferred-accepted`. |
| `sim test <run id> WelcomeAfterSkipProof` | After Skip for now, the welcome lists `/start`, `/workout`, `/plan`, `/status`, `/review`, and `/language` with localized titles, `welcome-after-skip`. `TutorialHarness.waitForWelcome` checks the same list wherever a connected proof reaches the welcome. |
| `sim test <run id> FirstConversationProof` | Onboarding reaches the composer and two complete turns, `04-first-conversation`. |
| `sim test <run id> UpgradeConnectionProof` | An existing pre-vault connection reaches the next turn, `upgrade-item`. The proof copies the bundled pre-vault record stores and writes a pre-vault `secrets.json` at launch; a missing store fails it. |
| `sim test <run id> LockedKeychainProof` | The kept conversation remains visible with the unlock notice, `locked-keychain`. Its training storage screens are on the [Settings page](./settings.md). |
| `sim test <run id> StorageUnavailableProof` | An unreadable store shows the history-unavailable and reopen notice, `storage-unavailable`. Debug builds also print the raw store error under the two sentences, with no identifier. |
| `sim test <run id> AccessNoticeProof` | An absent Credits key shows `This iPhone has no Credits. You can buy Credits.` with Buy Credits, which opens the Credits screen; a locked keychain preserves the message and offers Try again, `access-not-configured`, `access-not-configured-credits`, `access-locked`. |

The hosted `OnboardingConnectionTests` suite drives `ShellModel.connect`, correction, display retry, Continue, and failed saves. `FixtureLaunchTests.skippingThenConnectingInSettingsKeepsConversationAndReadsKeyOwner` preserves the skipped turn and reads Bo Lind's actual profile and calendar after Settings connection. Package `ConnectLaterTests.unofferedTrainingToolsThenSavedKeyOwnerReachTheModel` checks the real model input: no `intervals_*` tool is offered before the connection, a call to one returns `unknown_tool`, and after it the saved key owner's profile and calendar are read. `AccessOnboardingTests` drives ShellModel through the starter grant, Start chatting and a reopened text-and-tool turn, and through a failed grant that still starts chatting. Package `StarterGrantTests` retains the starter result and failure contract. The existing launch arguments select Credits setup, provisioning failure and failed credential writes.

## Gotchas

- Consent is never seeded by fixtures. The shared onboarding helpers tap Agree. App tests cover a failed consent write and retrying a refused turn; those paths still need their hosted tests to run.
- Use fixture launches. A launch without `-EnduragentFixture first-week` uses live services.
- Any non-empty fixture key is saved. Display faults do not change that receipt. `-EnduragentFixtureTrainingDisplay` takes `profile-rejected`, `profile-request-rejected`, `profile-unavailable`, `profile-offline`, `wellness-rejected`, `wellness-unavailable`, `empty-wellness`, or `partial-wellness`. Read failures occur once, so the real correction or retry can recover. `profile-offline` is the exception: every profile read fails as a phone with no connection until a relaunch without it, and the connect step shows the profile-unavailable notice with Try again. `-EnduragentFixtureCredentialWrite fail-once` fails the first connection write after fixture setup. These hooks prove the transaction and presentation, not live remote authentication.
- Settings owns connection actions. `fixture.connection`, `fixture.failCredentialWrite`, and `fixture.toggleKeychainLock` are Debug fault controls reached with `TutorialHarness.debugRow`.
- `-EnduragentFixtureKeychain locked` fails reads and writes. `unavailable` simulates a temporary secure-store outage. `malformed-intervals` writes synthetic malformed bytes into only the intervals.icu item. `TrainingStorageProof` proves their Settings corrections. `LockedKeychainProof` also checks training-specific unlock guidance and recovery. `empty` skips installing the fixture Credits key; use it with a fresh store because it does not erase a kept key.
- The connection proof uses the fixture's default day. Other dates may have no fixture wellness values.
- Record rows identify the account used by an attempt. The accepted athlete-message row is unconnected; claim and settlement rows carry that attempt's connection.

The access proof reuses `-EnduragentFixtureAccess credits-needs-setup` for an identity without a Credits key, `-EnduragentFixtureCredits unavailable`, `provisioning-failed` or `already-granted` for setup outcomes, and `-EnduragentFixtureCredentialWrite fail-once` for a failed key write. `unavailable` fails both grant and balance reads. No purchase or automatic overage is started.

- `-EnduragentFixtureAccess build9-openrouter` installs the fixture Credits key beside the OpenRouter key and the saved OpenRouter choice that a build 9 install leaves in the Keychain. The app never reads the saved choice, chats on Credits, and leaves the OpenRouter key in place. Delete everything removes both items with every other Keychain item of the app.
