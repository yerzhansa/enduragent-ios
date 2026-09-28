# Onboarding and connection

The athlete accepts the health notice, connects intervals.icu or skips it, receives starter Credits, and enters the one ongoing conversation. A kept store reopens that conversation. Debug, Credentials provides the existing controls for replacing or disconnecting the training connection.

## Sub-features

- `onboarding-notice` shows the health notice with `notice.continue`.
- `onboarding-connect` accepts a non-blank key, shows the connected athlete and training values, and offers `connect.continue`.
- `onboarding-connect-empty` keeps the connect screen and shows `intervals.icu did not accept that key.` in `connect.error`.
- `onboarding-skip` opens starter Credits without a training connection. The conversation welcome omits `/sync`.
- `onboarding-starter` shows `200 credits` and `Start chatting` in the fixture. A failed grant shows its catalog notice rather than a raw error.
- `onboarding-credentials` keeps the current connection after a blank replacement, Cancel, or a failed keychain write. A different athlete requires Switch athlete while work or a workout review is pending. A replacement for the same athlete keeps the review usable.
- `onboarding-unavailable` shows `launch.storageUnavailable` when the record store cannot open. A locked keychain on a kept store preserves the transcript and shows `chat.composer.notice`.

## How to get to it (user POV)

- Open the app with a fresh store and choose Continue.
- Enter an intervals.icu key and choose Connect, or choose Skip for now.
- Choose Continue after connection, then Start chatting after starter Credits.
- From the conversation, choose Menu, Debug, Credentials. The controls are Replace, Blank key, Cancel, Switch athlete, and Disconnect. Fixture builds also offer Lock keychain and Fail next write.
- Choose access method under a turn notice returns to the connect step; finishing it returns to the existing conversation.

## Driving it with sim.mjs and XCUITest

Preconditions:

- Follow the [index](./README.md) setup and require a passing doctor. Each proof prepares its own fixture state unless it needs an upgrade store.
- The fixture athlete is Ada Kovač, `i1001`, with Fitness 42, Fatigue 49, and Form -7 on 1998-06-15.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> InstallOpenProof` | Health notice and Continue, `01-install-open`. |
| `sim.mjs test <run id> ConnectIntervalsProof` | `connect.athleteName`, `.fitness`, `.fatigue`, and `.form` show the fixture values, `02-connect-intervals`. |
| `sim.mjs test <run id> StarterCreditsProof` | `starter.credits` and `starter.start`, `03-starter-credits`. |
| `sim.mjs test <run id> WelcomeAfterSkipProof` | Welcome after skipping has no `/sync`, `welcome-after-skip`. |
| `sim.mjs test <run id> FirstConversationProof` | Onboarding reaches the composer and two complete turns, `04-first-conversation`; network count stays zero. |
| `sim.mjs test <run id> CredentialTransactionProof` | Blank key, Cancel, and a failed replacement preserve Ada's key; the next reply succeeds, `credential-blank`, `credential-transaction`, `credential-transaction-reply`. |
| `sim.mjs test <run id> DifferentAthleteProof` | Replace with `other-athlete` refuses the switch while a review exists. Confirming Switch athlete removes approval controls, `different-athlete`, `switch-confirmed`. |
| `sim.mjs test <run id> SameAthleteRotationProof` | `fixture-rotated` keeps review authority for the same athlete, then approval succeeds, `same-athlete-rotation`, `same-athlete-rotation-added`. |
| `sim.mjs test <run id> DisconnectProof` | The next turn's record names `unconnected`, `disconnect`. |
| `sim.mjs test <run id> ConnectAfterLaunchProof` | Connecting after Skip affects the next turn without relaunch, `connect-after-launch`. |
| `sim.mjs test <run id> FailedWriteRecordsProof` | A failed replacement preserves the connection stamped on the next turn, `failed-write`, `failed-write-records`. |
| `sim.mjs test <run id> UpgradeConnectionProof` | An existing pre-vault connection reaches the next turn, `upgrade-item`. Requires its earlier store and keychain; a skip is not a pass. |
| `sim.mjs test <run id> LockedKeychainProof` | The kept conversation remains visible with the unlock notice, `locked-keychain`. |
| `sim.mjs test <run id> StorageUnavailableProof` | An unreadable store shows the history-unavailable and reopen notice, `storage-unavailable`. |
| `sim.mjs test <run id> AccessNoticeProof` | An absent Credits key opens the connect step; a locked keychain preserves the message and offers Try again, `access-not-configured`, `access-not-configured-connect`, `access-locked`. |

For the empty-key path, launch fresh, tap `notice.continue`, leave `connect.apiKey` empty, and tap `connect.connect`. Capture `connect.error` with `sim.mjs shot <run id> connect-empty-key`. This path has no dedicated XCUITest class. Grant-failure copy is covered by the hosted app test `creditsFailuresShowCatalogNotices`; no fixture directive reaches that failure.

## Gotchas

- Use fixture launches. A launch without `-EnduragentFixture first-week` uses live services.
- Any non-empty fixture key connects. This proves the connection transaction, not validation against the real intervals.icu service.
- `credentials.apiKey`, `.replace`, `.replaceBlank`, `.cancel`, `.switchAthlete`, `.disconnect`, `.lock`, and `.failNextWrite` identify the Debug controls. Read `.outcome`, `.athlete`, `.connection`, and `.keySuffix` afterwards.
- `-EnduragentFixtureKeychain locked` fails reads and writes. `empty` skips installing the fixture Credits key; use it with a fresh store because it does not erase a kept key.
- The connection proof uses the fixture's default day. Other dates may have no fixture wellness values.
- Record rows identify the account used by an attempt. The accepted athlete-message row is unconnected; claim and settlement rows carry that attempt's connection.
