# History

History contains archived conversations and opens each one read-only. There is still only one ongoing conversation. New conversation closes earlier messages into History; a v1 upgrade exposes earlier chats as archived conversations.

## Sub-features

- `history-empty` shows `No past conversations yet. Starting a new conversation keeps the old one here.` when nothing has been archived.
- `history-list` lists archived conversations newest first under the catalog title `Past chats`. Rows show the first athlete message, close reason, and start day.
- `history-reasons` shows `You started a new conversation` or `Earlier chat` for New conversation or v1 content respectively.
- `history-archived` opens `Past conversation` with the saved turns and review outcomes. `archive.readOnly` says `Past conversations are read-only.` There is no active composer or recovery action in the archived content.
- `history-upgrade` puts v1 chats in History and opens the ongoing conversation on the welcome.
- `history-unavailable` shows the catalog failure sentence if records cannot be read. Opening History starts no model request and runs no pending memory work.

## How to get to it (user POV)

- Choose Menu, then History from the ongoing conversation.
- Tap a `history.row.<id>` to read an archived conversation.
- Create an archive with the compose icon labeled New conversation or `/start`. The [conversation map](./chat.md) covers those paths.

## Driving it with sim.mjs and XCUITest

Preconditions:

- Follow the [index](./README.md) setup. Upgrade proofs additionally require the earlier store described in the verify-ios skill's Upgrade proofs section.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> HistoryListProof` | History is empty after the first reply; `/start` creates one row, `history-empty`, `history-list`. |
| `sim.mjs test <run id> HistoryArchivedProof` | The toolbar reset creates a row; opening it shows the prior question, reply, and read-only notice, `history-row`, `history-archived`. |
| `sim.mjs test <run id> OvernightConversationProof/testThirteenHoursLaterContinuesTheConversation` | A 13-hour gap across a relaunch leaves History empty, `m1-15-overnight-history`. |
| `sim.mjs test <run id> UpgradeHistoryProof` | Two v1 rows read Earlier chat; one opens read-only, `upgrade-welcome`, `upgrade-history`, `upgrade-history-read-only`. Missing prior data makes the proof skip. |
| `sim.mjs test <run id> HistoryOpenProbe/testSeedFiftyResets`, then `sim.mjs test <run id> HistoryOpenProbe/testHistoryOpenWithFiftyArchived` | The kept store has 50 archives; `history-open-ms` measures opening them and `history-with-fifty-archived` shows the list. |
| `sim.mjs test <run id> HistoryOpenProbe/testHistoryOpenWithNoneArchived` | A fresh store supplies the empty baseline, `history-open-empty-ms`. |

Compare the 50-archive and empty measurements under a one-minute load below 20. The acceptance bound is no more than one additional second for 50 archives. Do not loosen it after a load-related failure. The package test for History read failure supplies the unavailable case; there is no UI fixture directive for that read failure.

## Gotchas

- Fresh launch erases the fixture archives. Use a kept store between a seed and its measurement.
- Match the `history.row.` prefix. Its suffix is the boundary identifier or the earlier conversation identifier, not a stable sequence number.
- The fixture date is 1998-06-15 unless the proof supplies another clock instant.
- History reloads when it appears. It does not provide an action to resume an archived conversation.
- The Menu sheet leaves the ongoing conversation's controls in the accessibility tree behind it. Assert they are not hittable while reading History.
- Consecutive resets with no messages do not create empty History rows.
