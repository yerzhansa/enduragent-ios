# Enduragent iPhone verification map

Enduragent has one ongoing conversation. New conversation closes it into History and opens the welcome. Nothing closes it automatically, however long the gap between messages. History is read-only. A turn can be accepted, working, completed, failed, interrupted, or waiting for recovery. The feature files below describe the athlete's actions, the notices those states show, and the existing proofs that reach them.

## Baseline preconditions

Use the existing [verify-ios skill](../SKILL.md) and its helper, `swift run --quiet --package-path tools sim`, abbreviated below as `sim`. Build, create a dedicated run, install, and require `sim doctor <run id>` to pass before driving that run. Never drive another run's simulator. A proof launches the app itself; interactive steps need `sim launch <run id>` first.

A task that forbids simulators permits only the source and proof inventory checks. Record UI execution as skipped in that task's report. This map is a recipe, not evidence that its recipes ran.

## Driving conventions

- `sim launch <run id>` starts a fresh fixture store at the health notice. `sim launch <run id> --keep` keeps the conversation, drafts, settings, and connection.
- `sim test <run id> ClassName` runs an existing XCUITest class. `ClassName/testMethod` selects one method. Use the commands in each feature file; keep their `Passed` summary and named attachments.
- Prefer accessibility identifiers to visible labels. Labels in this map are English catalog values unless another language is explicit. Product chrome follows the language preference; Debug-only labels can remain English.
- Type `fixture` as the intervals.icu key. In fixture mode `other-athlete` resolves to Bo Lind, and other non-empty keys resolve to Ada Kovač. No real account is needed.
- Fixture directives are messages typed into `chat.composer`. See [chat.md](./chat.md) for failures, interruptions, storage faults, and memory work.
- `fixture.modelRequestCount` counts requests to the fake model and is expected to grow.
- Capture the action and resulting state. A skipped or unreachable entry point remains unverified, even if another path reaches the same screen.

## Debug entry points

Open `chat.settings`, then `settings.debug`. Settings exists in every build. Its Debug entry exists in Debug builds only.

| Entry | Handle | What to inspect |
| --- | --- | --- |
| Credits | `debug.credits` | Developer grant, balance, identity, and purchase diagnostics. Athlete Credits is `settings.credits`. |
| Credential fixture controls | `fixture.connection`, `fixture.failCredentialWrite`, `fixture.toggleKeychainLock` | Connection identity, failed write and lock/unlock hooks only. Product connection actions are Settings > intervals.icu. See [settings.md](./settings.md). |
| Records | `debug.records` | `records.count.<kind>`, `records.row.<id>`, and `records.refresh`. A refresh reads new records. |
| Language | `debug.language` | The same language choices opened by `/language`. See [language.md](./language.md). |
| Leases | `debug.leases` | `leases.row.<n>` and the visible `Refresh` button. See [chat.md](./chat.md). |
| Fixture counters and prompt text | Rows on Debug itself | `fixture.modelRequestCount`, `fixture.historyHead`, and `fixture.replyLanguage`. |

The Debug-only `chat.turnProgress` element exposes `turns <count> settled <settled count>`. Existing proofs use `TutorialHarness.exchange` to wait for a whole turn to settle.

## Feature files

| Feature | Coverage |
| --- | --- |
| [Onboarding](./onboarding.md) | Health notice, intervals.icu connection, starter Credits, and storage availability. |
| [Conversation](./chat.md) | Send, working and notice states, Try again, Stop, relaunch, memory work, New conversation, overnight continuity, and Debug settings. |
| [Language](./language.md) | All language rows, fixed language, Automatic on a French phone, saved-language first frame, and notice language. |
| [Workout review](./workout-preview.md) | Approve or cancel, durable outcomes, account changes, v1 notice connected and disconnected, and French review text. |
| [Settings](./settings.md) | Toolbar navigation, Credits under Model access, intervals.icu connection and calendar guidance, draft and setup continuity, and French icon actions. |
| [History](./history.md) | Archived conversations, close reasons, read-only content, upgrade, and open-time probes. |
| [Credits](./credits.md) | Credit count, disabled packs, unavailable notice, and recovery links from a turn. |

## Maintaining the map

Every feature file has `Sub-features`, `How to get to it (user POV)`, `Driving it with sim and XCUITest`, and `Gotchas`, in that order. Keep stable feature IDs and document uncovered paths as gaps.

Cross-check the class names against `apps/ios/EnduragentUITests/`. Every XCTestCase class, including latency probes, must appear in a feature file, and every named proof or probe must exist. Run `make check-source` for the cross-check and keep its output in the sweep report. It checks names and selected methods without launching the app. It does not establish that a proof passed.

Reach every Debug list row through `TutorialHarness.debugRow` before tapping it or reading its label. The helper scrolls with a deadline. Use `direction: .down` when returning from fixture counters to a row above them. Leave Settings and its destinations with `TutorialHarness.returnToChat`.
