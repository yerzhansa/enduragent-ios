# Onboarding and connection

The athlete accepts the health notice, connects intervals.icu or skips it, receives starter Credits, agrees to sharing with the AI providers, and enters the one ongoing conversation. A kept store without current consent opens the same consent screen before chat. Settings > intervals.icu provides replacement and confirmed disconnect.

## Sub-features

- `onboarding-notice` shows the health notice with `notice.continue`.
- `onboarding-connect` saves a non-blank key and shows `connect.saved` separately from profile or wellness guidance in `connect.notice`. `connect.displayAction` opens the empty masked field after rejection or retries unavailable display data with the saved connection. Available identity and wellness values stay visible, missing values have no row, and `connect.continue` works after a saved key even when its display failed.
- `onboarding-connect-empty` keeps the connect screen and shows `Enter an intervals.icu API key.` for a first connection and the current-connection sentence for a replacement in `connect.saved`. A first failed save says `The connection wasn't saved. Try again.` and offers another Connect or Skip. A replacement keeps the previous-connection sentence.
- `onboarding-skip` clears the typed key and edit state before opening starter Credits without a training connection. Later Settings opens on Connect and its field is empty, including after a late onboarding binding write. The conversation welcome lists the supported commands whether or not intervals.icu is connected. `fixture:training-data` reads the profile and calendar and explains their absence. Connecting through Settings preserves that turn and lets the next request read the key owner's data.
- `training-key-keyboard` uses one masked key field in onboarding and Settings, with autocorrection and capitalization disabled and an ASCII-capable keyboard. The connect-later proof launches with `ru,fr,en`, types two ASCII characters in the onboarding field, skips setup in French, then checks the Connect row and empty field before typing the key in Settings.
- `onboarding-starter` shows Credits in `starter.useCredits`, the starter result in `starter.credits`, then Sign in with OpenRouter in `starter.openRouter`. Both choices send the Settings intents and mark the saved method from CoachStatus. `starter.start` opens the conversation without selecting a method. A failed grant or choice shows its catalog notice instead of stale grant success.
- `onboarding-consent` names OpenRouter, the selected model, its receiving provider, and the data shared. Consent is local to this iPhone and applies to the disclosed access method and recipient. A legacy agreement and another device's agreement cannot authorize a new provider. `consent.accept` saves permission and opens chat. `consent.decline` keeps chat locked and shows the same disclosure with `consent.resume` labeled Agree and continue. One tap saves permission and opens chat without repeating the choice or requesting starter Credits. Relaunching before agreement asks again.
- `onboarding-credentials` is now proved by the [Settings connection proofs](./settings.md). Settings keeps the current connection after a blank replacement, Cancel, or a failed keychain write. A different athlete requires Switch athlete while work or a workout review is pending. A replacement for the same athlete keeps the review usable.
- `onboarding-unavailable` shows `launch.storageUnavailable` when the record store cannot open. A locked keychain on a kept store preserves the transcript and shows `chat.composer.notice`.

## How to get to it (user POV)

- Open the app with a fresh store and choose Continue.
- Enter an intervals.icu key and choose Connect, or choose Skip for now.
- Choose Continue after connection, or Skip for now. Choose Credits or Sign in with OpenRouter on the starter step, then Start chatting. Successful sign-in selects OpenRouter; cancellation and failures keep the saved choice.
- Read Your coach uses AI, then choose Agree and continue or Not now. After Not now, tap Agree and continue once to open chat. A saved turn refused for missing consent stays unchanged after agreement until the athlete taps Try again.
- From the conversation, choose Settings > intervals.icu. Choose Replace key, enter the masked value and save. Known owner changes and Disconnect need explicit confirmation. Debug holds only credential fault controls.
- Choose access method under a turn notice returns to the connect step; finishing it returns to the existing conversation.

## Driving it with sim.mjs and XCUITest

Preconditions:

- Follow the [index](./README.md) setup and require a passing doctor. Each proof prepares its own fixture state unless it needs an upgrade store.
- The fixture athlete is Ada Kovač, `i1001`, with Fitness 42, Fatigue 49, and Form -7 on 1998-06-15.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> InstallOpenProof` | Health notice and Continue, `01-install-open`. |
| `sim.mjs test <run id> ConnectIntervalsProof ConnectIntervalsDarkProof` | Blank and failed saves, saved profile rejection, rejected profile request, temporary profile failure, wellness rejection and outage, no wellness and missing values, then correction or retry. Attachments start with `onboarding-` and end with `light` or `dark`. Skip and later Settings connection with a Russian-first language list produce `skipped-training-data-unavailable`, `settings-latin-key-saved`, and `connected-later-conversation-kept`, with the same theme suffix. |
| `sim.mjs test <run id> AccessOnboardingProof` in light and dark | Credits and grant before sign-in, saved choice in Settings after relaunch, unavailable provisioning and reads, failed credential and selection writes, already granted without a usable key, and cancelled sign-in with either previous method. The sign-in outcome proof covers success, cancellation, rejected callback, exchange failure, failed key and selection writes, and two taps joining a held sign-in. Attachments start with `access-onboarding-` and end with `light` or `dark`. Run the same class separately after setting each simulator appearance. |
| `sim.mjs test <run id> StarterCreditsProof` | `starter.credits` and `starter.start`, `03-starter-credits`. |
| `sim.mjs test <run id> OpenRouterConsentProof` in light and dark | First sign-in names the built-in model and provider. Another device's synced selection names its model and provider before any model request. Decline and relaunch keep requests at zero. Attachments start with `openrouter-consent-` and end with `light` or `dark`. |
| `sim.mjs test <run id> ProviderConsentProof` | Consent before chat, decline without opening chat, consent on relaunch, a deferred consent screen without starter Credits, and one saved consent after one Agree tap, `provider-consent`, `provider-consent-deferred`, and `provider-consent-deferred-accepted`. |
| `sim.mjs test <run id> WelcomeAfterSkipProof` | Welcome lists `/start`, `/workout`, `/status`, `/review`, and `/language` with localized titles whether or not intervals.icu is connected, `welcome-after-skip`. |
| `sim.mjs test <run id> FirstConversationProof` | Onboarding reaches the composer and two complete turns, `04-first-conversation`; network count stays zero. |
| `sim.mjs test <run id> UpgradeConnectionProof` | An existing pre-vault connection reaches the next turn, `upgrade-item`. Requires its earlier store and keychain; a skip is not a pass. |
| `sim.mjs test <run id> LockedKeychainProof` | The kept conversation remains visible with the unlock notice, `locked-keychain`. |
| `sim.mjs test <run id> StorageUnavailableProof` | An unreadable store shows the history-unavailable and reopen notice, `storage-unavailable`. |
| `sim.mjs test <run id> AccessNoticeProof` | An absent Credits key opens the connect step; a locked keychain preserves the message and offers Try again, `access-not-configured`, `access-not-configured-connect`, `access-locked`. |

The hosted `OnboardingConnectionTests` suite drives `ShellModel.connect`, correction, display retry, Continue, and failed saves. `FixtureLaunchTests.skippingThenConnectingInSettingsKeepsConversationAndReadsKeyOwner` preserves the skipped turn and reads Bo Lind's actual profile and calendar after Settings connection. Package `ConnectLaterTests.missingTrainingToolResultsThenSavedKeyOwnerReachTheModel` checks the real model input, including both `not_connected` tool results and the saved key owner's profile and calendar. `AccessOnboardingTests` drives ShellModel through starter setup, explicit choices, completion, Settings and a reopened text-and-tool turn. Package `StarterGrantTests` retains the starter result and failure contract. The existing launch arguments select Credits setup, provisioning failure and failed credential writes.

## Gotchas

- Consent is never seeded by fixtures. The shared onboarding helpers tap Agree. App tests cover a failed consent write and retrying a refused turn; those paths still need their hosted tests to run.
- Use fixture launches. A launch without `-EnduragentFixture first-week` uses live services.
- Any non-empty fixture key is saved. Display faults do not change that receipt. `-EnduragentFixtureTrainingDisplay` takes `profile-rejected`, `profile-request-rejected`, `profile-unavailable`, `wellness-rejected`, `wellness-unavailable`, `empty-wellness`, or `partial-wellness`. Read failures occur once, so the real correction or retry can recover. `-EnduragentFixtureCredentialWrite fail-once` fails the first connection write after fixture setup. These hooks prove the transaction and presentation, not live remote authentication.
- Settings owns connection actions. `fixture.connection`, `fixture.failCredentialWrite`, and `fixture.toggleKeychainLock` are Debug fault controls reached with `TutorialHarness.debugRow`.
- `-EnduragentFixtureKeychain locked` fails reads and writes. `unavailable` simulates a temporary secure-store outage. `malformed-intervals` writes synthetic malformed bytes into only the intervals.icu item. `TrainingStorageProof` and `TrainingStorageDarkProof` prove their Settings corrections. `LockedKeychainProof` also checks training-specific unlock guidance and recovery. `empty` skips installing the fixture Credits key; use it with a fresh store because it does not erase a kept key.
- The connection proof uses the fixture's default day. Other dates may have no fixture wellness values.
- Record rows identify the account used by an attempt. The accepted athlete-message row is unconnected; claim and settlement rows carry that attempt's connection.

The access proof reuses `-EnduragentFixtureAccess credits-needs-setup` or `openrouter-needs-credits` for an identity without a Credits key, `-EnduragentFixtureCredits unavailable`, `provisioning-failed` or `already-granted` for setup outcomes, and `-EnduragentFixtureCredentialWrite fail-once` for a failed key write. `unavailable` fails both grant and balance reads. A keep launch preserves the saved choice. No purchase or automatic overage is started. OpenRouterConsentProof and the access proofs cover the fake sign-in outcomes. Signed-phone sign-in and browser cancellation remain live checks.

- `-EnduragentFixtureSignIn` selects `success`, `cancel`, `rejected-callback`, `exchange-failure`, or `held`. A held sign-in exposes `fixture.signInCount` and `fixture.completeSignIn` on the access screen. Tap Sign in twice, then complete it; both taps join one authorization.
- `-EnduragentFixtureAccess synced-openrouter` seeds the Anthropic-hosted Claude Sonnet 4.5 selection before the first local request. `-EnduragentFixtureCredentialWrite fail-selection` reuses the existing selection-slot write fault; `fail-once` fails the candidate key write during sign-in.

`OpenRouterRecoveryProof` covers missing/rejected/403 recovery and overlapping requests. `OpenRouterAccessProof` covers Settings and onboarding sign-in/cancel marks, relaunch and tool replies. Run both classes in light and dark. The guarded live procedure is in the skill's real-phone OpenRouter recovery section.
