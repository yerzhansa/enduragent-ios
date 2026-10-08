# Settings

Settings opens from the conversation toolbar. Credits lives under Model access. intervals.icu lives under Training connection. History has its own toolbar action. New conversation keeps its compose icon.

## Sub-features

- `settings-navigation` opens `chat.settings` after connected setup or Skip, and after relaunch. Back returns to the same conversation and draft.
- `settings-model-access` contains `settings.credits`, which opens the existing Credits screen. Both Buy buttons remain disabled.
- `settings-model-choice` contains `settings.model` only when the access snapshot supplies OpenRouter model choices. It opens the catalog-only picker with the saved row marked. A selected model omitted by a newer catalog keeps its stored name and provider. Rows send the existing model-selection intent; another provider uses the existing consent route before committing the choice.
- `settings-debug` contains `settings.debug` in Debug builds only. Records, Credits diagnostics, Language, Leases, and fixture controls remain reachable.
- `settings-session` contains `settings.session` in every build. It opens Session with the history budget in percent and the context window in tokens. The fields show the saved values, 30 and an empty field with the `Default` placeholder when nothing is saved. Editing a field shows Save and Cancel. A rejected value shows its field's catalog sentence and saves neither field. A failed save shows the not-saved notice and keeps the saved value. Cancel or leaving the screen drops the unfinished edit. No reset, retention or maintenance-model control exists.
- `settings-sections` contains Model access, Training connection, Language, Session and the Debug entry, in that order. Notifications, Diagnostics, Feedback, About, and Your data have no row or section.
- `settings-toolbar-language` uses catalog labels on icon buttons at 390 pt iPhone width. History uses `archive.history` for both the toolbar label and screen title. French actions have no drawn text, overlap, or frame overflow.
- `settings-training` connects, replaces or keeps the key, confirms a different owner and disconnect, and separates the save receipt from profile/wellness notices. The key field is always masked and never contains the stored key.
- `settings-calendar-connect` offers Connect after an unconnected Add to calendar. It opens the masked Settings editor without restarting setup.
- `settings-training-storage` gives missing, locked, unavailable and malformed connections distinct guidance. Missing offers Connect, malformed offers Replace key, and locked or unavailable storage offers Try again with unlock or recovery guidance. Correction replaces only the malformed training item and preserves earlier athlete safeguards.
- `settings-continuity` keeps the connection, conversation, slash draft, and command discovery through navigation and a relaunch from Settings.

## How to get to it (user POV)

- Finish connected setup or choose Skip, then accept provider consent.
- Tap the gear icon labeled Settings in the toolbar.
- Tap intervals.icu under Training connection. Choose Connect or Replace key to open the empty masked field. Save checks for a nonempty key. A known owner change with bound work asks for Switch athlete. Cancel or Keep current connection preserves the account. Disconnect asks for confirmation and keeps the conversation and History.
- Tap Credits under Model access. Use Back to return to Settings, then the conversation.
- Tap the toolbar History icon to open read-only History directly.
- Tap Session under Session. Replace a value, press Return, then tap Save or Cancel.
- In Debug builds, tap Settings, Debug, then the required diagnostic row.
- Type `/` in the composer to discover commands. Tap New conversation to archive the conversation and open the welcome.

## Driving it with sim and XCUITest

Follow the [index](./README.md) setup. Use a 390 pt wide iPhone.

| Command | Observable result and attachment |
| --- | --- |
| `sim test <run id> SettingsNavigationProof` | Connected setup, Skip, and French each open Settings, disabled Credits packs, and toolbar History, return to the conversation and slash draft, relaunch from Settings, preserve the working connection, select a command, and archive through New conversation. Attachments start with `settings-connected-en`, `settings-skipped-en`, or `settings-connected-fr`, followed by `light` and `toolbar`, `page`, `credits`, `command`, or `archive`. |
| `sim test <run id> ConnectAfterLaunchProof` | Connect after Skip, relaunch, cancel replacement, and continue the conversation. `connect-later-before`, `connect-later-saved`, `connect-later-history`. |
| `sim test <run id> CredentialTransactionProof` | Keep, blank input and Cancel preserve the working connection. The field is secure, empty and has the catalog placeholder. `replacement-blank`, `replacement-cancel-records`. |
| `sim test <run id> FailedWriteRecordsProof` | Failed write says the replacement was not saved; the next turn keeps its previous account. `replacement-not-saved`, `replacement-not-saved-records`. |
| `sim test <run id> SameAthleteRotationProof` | Rotation changes connection ID for the same athlete, keeps the workout review and saves the approved workout. `same-athlete-saved`, `same-athlete-added`. |
| `sim test <run id> DifferentAthleteProof` | Known owner change asks for confirmation; Cancel keeps Ada, Switch athlete saves Bo and disables the old workout review. `different-athlete-confirmation`, `different-athlete-saved`, `different-athlete-old-review`. |
| `sim test <run id> DisconnectProof` | Cancel keeps the connection. Confirmed disconnect offers Connect, preserves History and the current conversation, and stamps the next turn unconnected. `disconnect-confirmation`, `disconnected-connect-offered`, `disconnected-history`, `disconnected-next-turn`. |
| `sim test <run id> TrainingStorageProof LockedKeychainProof` | Unavailable storage preserves the conversation and recovers after restoring the fixture store and tapping Try again. Malformed storage supports Cancel, blank input, failed write and successful correction with an empty masked editor. Screenshots start with `training-storage-` or `training-correction-`; locked proof adds `locked-training-storage` and `unlocked-training-storage`. Synthetic secrets stay absent from visible text and record rows. |
| `sim test <run id> UnconnectedCalendarProof` | Add to calendar gives missing-connection guidance and a working Connect route to Settings. `unconnected-calendar-notice`, `unconnected-calendar-connect`. |
| `sim test <run id> SessionSettingsProof` | With Credits and with an OpenRouter account, the defaults, units and catalog text show, each field saves alone and survives a relaunch, and the access method is unchanged. Cancel and Back drop an unfinished edit and write no record. A failed save shows the not-saved notice, keeps the saved value and the conversation, and survives a relaunch. Attachments start with `session-credits-`, `session-catalog-openrouter-`, `session-cancel-` or `session-save-failed-` and end with `light`. |
| `sim test <run id> CoalesceProof StarterCreditsProof NoticeCopyProof` | Records stays open, Credits diagnostics remains hittable, and one Back from notice recovery returns to the conversation. |
| `sim test <run id> CreditsProof HistoryListProof HistoryArchivedProof NewConversationProof SlashStartProof ResetKeepsReviewProof` | Existing Credits, read-only History, both New conversation entries, and a reset with a pending workout review use the new routes. |
| `sim test <run id> ModelPickerProof` | Proves catalog selection and relaunch, newer and omitted-selected refreshes, malformed/stale/offline/empty retention with tappable rows and replies, no picker under Credits, leaving and failed writes, and named provider consent before acceptance or decline. Attachments start with `model-picker-` and end with `light`. |

Each training attachment above ends with `light`. Resolved fixture identity is Ada Kovač, Fitness 42, Fatigue 49, Form -7.

The hosted `TrainingStorageTests` suite covers missing, locked, temporarily unavailable and malformed training storage, retained conversation after relaunch, the shared malformed-training notice route, and retry or Replace through ShellModel.

The hosted `TrainingSettingsTests` suite covers editor persistence, receipt truth, next-turn account, confirmations and notice routing through ShellModel. `SingleProposalReviewsTests.unconnectedApprovalOffersConnectWithoutDispatch` proves that an unconnected Add records no write intent or dispatch.

The hosted `SessionSettingsScreenTests` cases drive `ShellModel.saveSession` and reopened stores. They cover each field saved alone, a rejected value beside a valid one, a failed save with the notice, the saved value and the conversation kept, and Cancel.

The hosted `ModelPickerTests` suite drives `ShellModel.chooseModel`, status observation and reopened stores. It covers a saved same-provider choice, leaving or failed selection writes, and accepted, declined or failed provider proposals through the existing consent route. Package `ModelChoiceTests`, `ModelCatalogRefreshTests` and `ProviderConsentTests` own model-request identity, cache persistence and request gating.

Picker handles are `settings.model`, `model.choices`, `model.choice.<catalog model ID>` and `model.notice`. Fixture-only `fixture.catalogState` reports `bundled` or `downloaded` followed by `available`, `refreshing`, or `retained <issue>`. Launch with `-EnduragentFixtureAccess catalog-openrouter` and `-EnduragentFixtureCatalog newer`, `omitted-selected-model`, `malformed`, `stale`, `offline`, `empty`, or `held`. `-EnduragentFixtureStore keep` preserves catalog and selection. `-EnduragentFixtureCredentialWrite fail-selection` targets the selection item. Picker model names and providers come from validated catalog entries, not typed IDs.

During the real-phone session run the guarded OpenRouter helper's `signin`, `pick`, then `tool` steps. `pick` requires the exact catalog ID, display name and hosting provider and sends zero messages. It taps that catalog row, waits for the operator to read and accept any provider disclosure, then checks the mark and saved ID after relaunch. `tool` needs a fresh one-message budget and the ID confirmed by `pick`. Keep live sign-in, selection and a completed tool-backed turn pending while the operator is away.

Both Settings classes also run `testEveryDebugDestinationReturnsToDebug`. They open all four Debug destinations, capture each screen, and check that one Back returns to Debug. The Credits steps check that one Back returns to Settings.

The hosted app tests in `SettingsNavigationTests.swift` drive `ShellModel.open`, `loadCredits`, `loadHistory`, `newConversation`, and `fillSlash`. Run `EnduragentTests` on the final head. The connected and skipped cases also reopen their stores and keep the draft and training setup. Status and conversation updates leave all five Debug destinations on the shell path. Credits opened from Model access returns to Settings after one Back. The notice-action tests require Credits opened from a conversation notice to return to the conversation after one Back.

`TutorialHarness.openSettings` opens the toolbar Settings route. `openHistory` taps `chat.history`. `openDebug`, `fixtureControl`, `openRecords`, `openCredentials`, and `historyHead` enter through Settings. `debugRow` scrolls until the Debug row can be tapped, and gives up only once the list has stopped moving. `returnToChat` leaves Settings through navigation Back with a deadline. Run every proof that calls those helpers on the final head. The suite covers these consumers, including History and New conversation. Run `HistoryOpenProbe` separately because the suite discovers proof classes only.

The device-only native persistence test uses the dedicated phone proof build to save a synthetic credential through Settings, relaunch with native Keychain storage, and complete profile and calendar reads. Follow the [real-phone procedure](../SKILL.md#prove-native-training-persistence-on-one-phone). It records native timings, secret-free receipts, the build version, the message budget and the device-update confirmation. This proof remains pending while the operator is away.

## Gotchas

- `TutorialHarness.openCredentials` now opens Settings > intervals.icu. It never opens Debug. Connection IDs are inspected only through `fixture.connection` in Debug; the helper returns to the product screen afterward.
- Credential failure hooks are Debug-only `fixture.failCredentialWrite` and `fixture.toggleKeychainLock`, `fixture.restoreSecureStorage`, and `fixture.corruptIntervals`. Reach them with `fixtureControl` and `debugRow`.
- Settings uses the shared 4.1 display notices and retry intent. Remote rejection opens the empty masked editor; temporary display failure retries with the saved connection ID. No new key is required for that retry.
- Settings and onboarding use `IntervalsKeyField` for the same secure ASCII-capable input. `ConnectIntervalsProof` types a key in Settings after launching with `ru,fr,en`, then verifies the saved result and retained conversation.

- Settings and History are navigation destinations. Swipe-down sheet dismissal cannot return to the conversation.
- Turn recovery opens Credits directly above the conversation. One Back returns to the conversation. Credits opened from Model access returns to Settings. Both entries use the same screen and perform no purchase or restore.
- The shell owns one typed navigation path and one stack. Every pushed Debug screen and archived conversation has a registered shell destination. A presented Language sheet owns its separate stack.
- Debug tools compile out of Release. A Debug screenshot does not prove their absence in a Release build.
- The Settings proof checks fixture connection identity. It does not prove live credentials or cross-device sync.
- The physical `PhoneRun` uses the new History and Settings > Credits routes. Its message budget and device approval requirements still apply.
- A task that forbids simulators can build these proofs and check their inventory. Their screenshots and runtime results remain pending until the simulator runner executes them.

`OpenRouterRecoveryProof` covers missing/rejected/403 recovery and overlapping requests. `OpenRouterAccessProof` covers Settings and onboarding sign-in/cancel marks, relaunch and tool replies. The guarded live procedure is in the skill's real-phone OpenRouter recovery section.
