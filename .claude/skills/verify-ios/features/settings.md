# Settings

Settings opens from the conversation toolbar. Credits lives under Model access. History has its own toolbar action. New conversation keeps its compose icon.

## Sub-features

- `settings-navigation` opens `chat.settings` after connected setup or Skip, and after relaunch. Back returns to the same conversation and draft.
- `settings-model-access` contains `settings.credits`, which opens the existing Credits screen. Both Buy buttons remain disabled.
- `settings-debug` contains `settings.debug` in Debug builds only. Records, Credentials, Credits diagnostics, Language, Session, Leases, and fixture controls remain reachable.
- `settings-sections` contains only Model access and the Debug entry. Future sections appear only when they have rows, in this order: Model access, Training connection, Language, Session. Notifications, Diagnostics, Feedback, About, and Your data have no row or section.
- `settings-toolbar-language` uses catalog labels on icon buttons at 390 pt iPhone width. History uses `archive.history` for both the toolbar label and screen title. French actions have no drawn text, overlap, or frame overflow.
- `settings-continuity` keeps the connection, conversation, slash draft, and command discovery through navigation and a relaunch from Settings.

## How to get to it (user POV)

- Finish connected setup or choose Skip, then accept provider consent.
- Tap the gear icon labeled Settings in the toolbar.
- Tap Credits under Model access. Use Back to return to Settings, then the conversation.
- Tap the toolbar History icon to open read-only History directly.
- In Debug builds, tap Settings, Debug, then the required diagnostic row. Session remains a Debug-only proof tool until the normal screen ships.
- Type `/` in the composer to discover commands. Tap New conversation to archive the conversation and open the welcome.

## Driving it with sim.mjs and XCUITest

Follow the [index](./README.md) setup. Use a 390 pt wide iPhone. The helper sets dark appearance for dark proof classes.

| Command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> SettingsNavigationProof SettingsNavigationDarkProof` | Connected setup, Skip, and French each open Settings, disabled Credits packs, and toolbar History, return to the conversation and slash draft, relaunch from Settings, preserve the working connection, select a command, and archive through New conversation. Attachments start with `settings-connected-en`, `settings-skipped-en`, or `settings-connected-fr`, followed by `light` or `dark` and `toolbar`, `page`, `credits`, `command`, or `archive`. |
| `sim.mjs test <run id> CreditsProof HistoryListProof HistoryArchivedProof NewConversationProof SlashStartProof ResetKeepsReviewProof` | Existing Credits, read-only History, both New conversation entries, and a reset with a pending workout review use the new routes. |

The hosted app tests in `SettingsNavigationTests.swift` drive `ShellModel.open`, `loadCredits`, `loadHistory`, `newConversation`, and `fillSlash`. Run `EnduragentTests` on the final head. The connected and skipped cases also reopen their stores and keep the draft and training setup. Status updates leave Settings and the Debug Session destination open.

`TutorialHarness.openSettings` replaces `openSidebar`. `openHistory` taps `chat.history`. `openDebug`, `fixtureControl`, `openRecords`, `openCredentials`, `historyHead`, and `assertZeroFixtureRequests` enter through Settings. `returnToChat` replaces `closeMenu` and taps navigation Back with a deadline. Run every proof that calls those helpers on the final head. The suite covers these consumers, including History and New conversation. Run `HistoryOpenProbe` separately because the suite discovers proof classes only.

## Gotchas

- Settings and History are navigation destinations. Swipe-down sheet dismissal cannot return to the conversation.
- Turn recovery opens the same Settings > Credits path. It performs no purchase or restore.
- Debug tools compile out of Release. A Debug screenshot does not prove their absence in a Release build.
- The Settings proof checks fixture connection identity and zero blocked network requests. It does not prove live credentials or cross-device sync.
- The physical `PhoneRun` uses the new History and Settings > Credits routes. Its message budget and device approval requirements still apply.
- A task that forbids simulators can build these proofs and check their inventory. Their screenshots and runtime results remain pending until the simulator runner executes them.
