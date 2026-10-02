# Settings

Settings opens from the conversation toolbar. Credits lives under Model access. intervals.icu lives under Training connection. History has its own toolbar action. New conversation keeps its compose icon.

## Sub-features

- `settings-navigation` opens `chat.settings` after connected setup or Skip, and after relaunch. Back returns to the same conversation and draft.
- `settings-model-access` contains `settings.credits`, which opens the existing Credits screen. Both Buy buttons remain disabled.
- `settings-debug` contains `settings.debug` in Debug builds only. Records, Credits diagnostics, Language, Session, Leases, and fixture controls remain reachable.
- `settings-sections` contains Model access, Training connection and the Debug entry. Further sections appear only when they have rows, with Language and Session after Training connection. Notifications, Diagnostics, Feedback, About, and Your data have no row or section.
- `settings-toolbar-language` uses catalog labels on icon buttons at 390 pt iPhone width. History uses `archive.history` for both the toolbar label and screen title. French actions have no drawn text, overlap, or frame overflow.
- `settings-training` connects, replaces or keeps the key, confirms a different owner and disconnect, and separates the save receipt from profile/wellness notices. The key field is always masked and never contains the stored key.
- `settings-calendar-connect` offers Connect after an unconnected Add to calendar. It opens the masked Settings editor without restarting setup.
- `settings-continuity` keeps the connection, conversation, slash draft, and command discovery through navigation and a relaunch from Settings.

## How to get to it (user POV)

- Finish connected setup or choose Skip, then accept provider consent.
- Tap the gear icon labeled Settings in the toolbar.
- Tap intervals.icu under Training connection. Choose Connect or Replace key to open the empty masked field. Save checks for a nonempty key. A known owner change with bound work asks for Switch athlete. Cancel or Keep current connection preserves the account. Disconnect asks for confirmation and keeps the conversation and History.
- Tap Credits under Model access. Use Back to return to Settings, then the conversation.
- Tap the toolbar History icon to open read-only History directly.
- In Debug builds, tap Settings, Debug, then the required diagnostic row. Session remains a Debug-only proof tool until the normal screen ships.
- Type `/` in the composer to discover commands. Tap New conversation to archive the conversation and open the welcome.

## Driving it with sim.mjs and XCUITest

Follow the [index](./README.md) setup. Use a 390 pt wide iPhone. The helper sets dark appearance for dark proof classes.

| Command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> SettingsNavigationProof SettingsNavigationDarkProof` | Connected setup, Skip, and French each open Settings, disabled Credits packs, and toolbar History, return to the conversation and slash draft, relaunch from Settings, preserve the working connection, select a command, and archive through New conversation. Attachments start with `settings-connected-en`, `settings-skipped-en`, or `settings-connected-fr`, followed by `light` or `dark` and `toolbar`, `page`, `credits`, `command`, or `archive`. |
| `sim.mjs test <run id> ConnectAfterLaunchProof ConnectAfterLaunchDarkProof` | Connect after Skip, relaunch, cancel replacement, and continue the conversation. `connect-later-before`, `connect-later-saved`, `connect-later-history`. |
| `sim.mjs test <run id> CredentialTransactionProof CredentialTransactionDarkProof` | Keep, blank input and Cancel preserve the working connection. The field is secure, empty and has the catalog placeholder. `replacement-blank`, `replacement-cancel-records`. |
| `sim.mjs test <run id> FailedWriteRecordsProof FailedWriteRecordsDarkProof` | Failed write says the replacement was not saved; the next turn keeps its previous account. `replacement-not-saved`, `replacement-not-saved-records`. |
| `sim.mjs test <run id> SameAthleteRotationProof SameAthleteRotationDarkProof` | Rotation changes connection ID for the same athlete, keeps the workout review and saves the approved workout. `same-athlete-saved`, `same-athlete-added`. |
| `sim.mjs test <run id> DifferentAthleteProof DifferentAthleteDarkProof` | Known owner change asks for confirmation; Cancel keeps Ada, Switch athlete saves Bo and disables the old workout review. `different-athlete-confirmation`, `different-athlete-saved`, `different-athlete-old-review`. |
| `sim.mjs test <run id> DisconnectProof DisconnectDarkProof` | Cancel keeps the connection. Confirmed disconnect offers Connect, preserves History and the current conversation, and stamps the next turn unconnected. `disconnect-confirmation`, `disconnected-connect-offered`, `disconnected-history`, `disconnected-next-turn`. |
| `sim.mjs test <run id> UnconnectedCalendarProof UnconnectedCalendarDarkProof` | Add to calendar gives missing-connection guidance and a working Connect route to Settings. `unconnected-calendar-notice`, `unconnected-calendar-connect`. |
| `sim.mjs test <run id> CoalesceProof StarterCreditsProof NoticeCopyProof` | Records stays open, Credits diagnostics remains hittable, and one Back from notice recovery returns to the conversation. |
| `sim.mjs test <run id> CreditsProof HistoryListProof HistoryArchivedProof NewConversationProof SlashStartProof ResetKeepsReviewProof` | Existing Credits, read-only History, both New conversation entries, and a reset with a pending workout review use the new routes. |

Each training attachment above ends with `light` or `dark`. Resolved fixture identity is Ada Kovač, Fitness 42, Fatigue 49, Form -7.

The hosted `TrainingSettingsTests` suite covers editor persistence, receipt truth, next-turn account, confirmations and notice routing through ShellModel. `SingleProposalReviewsTests.unconnectedApprovalOffersConnectWithoutDispatch` proves that an unconnected Add records no write intent or dispatch.

Both Settings classes also run `testEveryDebugDestinationReturnsToDebug`. They open all five Debug destinations, capture each screen, and check that one Back returns to Debug. The Credits steps check that one Back returns to Settings.

The hosted app tests in `SettingsNavigationTests.swift` drive `ShellModel.open`, `loadCredits`, `loadHistory`, `newConversation`, and `fillSlash`. Run `EnduragentTests` on the final head. The connected and skipped cases also reopen their stores and keep the draft and training setup. Status and conversation updates leave all five Debug destinations on the shell path. Credits opened from Model access returns to Settings after one Back. The notice-action tests require Credits opened from a conversation notice to return to the conversation after one Back.

`TutorialHarness.openSettings` opens the toolbar Settings route. `openHistory` taps `chat.history`. `openDebug`, `fixtureControl`, `openRecords`, `openCredentials`, `historyHead`, and `assertZeroFixtureRequests` enter through Settings. `debugRow` scrolls to each Debug row with a deadline. `returnToChat` leaves Settings through navigation Back with a deadline. Run every proof that calls those helpers on the final head. The suite covers these consumers, including History and New conversation. Run `HistoryOpenProbe` separately because the suite discovers proof classes only.

## Gotchas

- `TutorialHarness.openCredentials` now opens Settings > intervals.icu. It never opens Debug. Connection IDs are inspected only through `fixture.connection` in Debug; the helper returns to the product screen afterward.
- Credential failure hooks are Debug-only `fixture.failCredentialWrite` and `fixture.toggleKeychainLock`. Reach them with `fixtureControl` and `debugRow`.
- Settings uses the shared 4.1 display notices and retry intent. Remote rejection opens the empty masked editor; temporary display failure retries with the saved connection ID. No new key is required for that retry.
- Settings and onboarding use `IntervalsKeyField` for the same secure ASCII-capable input. `ConnectIntervalsProof` and `ConnectIntervalsDarkProof` type a key in Settings after launching with `ru,fr,en`, then verify the saved result and retained conversation.

- Settings and History are navigation destinations. Swipe-down sheet dismissal cannot return to the conversation.
- Turn recovery opens Credits directly above the conversation. One Back returns to the conversation. Credits opened from Model access returns to Settings. Both entries use the same screen and perform no purchase or restore.
- The shell owns one typed navigation path and one stack. Every pushed Debug screen and archived conversation has a registered shell destination. A presented Language sheet owns its separate stack.
- Debug tools compile out of Release. A Debug screenshot does not prove their absence in a Release build.
- The Settings proof checks fixture connection identity and zero blocked network requests. It does not prove live credentials or cross-device sync.
- The physical `PhoneRun` uses the new History and Settings > Credits routes. Its message budget and device approval requirements still apply.
- A task that forbids simulators can build these proofs and check their inventory. Their screenshots and runtime results remain pending until the simulator runner executes them.
