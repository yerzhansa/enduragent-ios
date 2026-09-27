# History

The menu's History screen, titled `Past chats`, lists archived conversations newest first. `Start new conversation` or `/start` archives the current conversation, and after an upgrade every chat a v1 build kept becomes one archived conversation. Each row shows the first message, why the conversation closed, and its start day. Choosing a row opens it read-only.

## Sub-features

- `history-empty` reads `No past conversations yet. Starting a new conversation keeps the old one here.` while the current conversation is the only one.
- `history-list` shows one `history.row.<boundary>` row per archived conversation with its first message, its reason, and `1998-06-15`. The reason reads `You started a new conversation` after `Start new conversation` or `/start`, `Closed after a break` after an automatic daily reset, and `Earlier chat` for a chat from a v1 build.
- `history-archived` pushes `Past conversation`, the old questions and replies with no composer, no `Try again`, and `Past conversations are read-only.` in `archive.readOnly`.
- `history-upgrade` opens a store written by a v1 build with two chats on the welcome, and History lists both as `Earlier chat`.
- `history-no-network` reads records only. Opening History makes no model request and drains no pending memory job.

## How to get to it (user POV)

- In the chat, choose `Menu`, then `History`.

## Driving it with sim.mjs and XCUITest

Preconditions:

- `sim.mjs doctor <run id>` exits 0 and the app is installed.
- For interactive steps, the app is on the chat after onboarding and at least one message has a reply.

- **Empty, then one row.** Run `sim.mjs test <run id> HistoryListProof`. After the week question, History shows the empty line and no row. After `/start`, it shows one row with the question, `You started a new conversation`, and `1998-06-15`. Attachments `history-empty` and `history-list` show them.
- **Read an archived conversation.** Run `sim.mjs test <run id> HistoryArchivedProof`. After `chat.newConversation`, the row reads `You started a new conversation`, and the pushed screen shows the question, the reply, and `archive.readOnly`. Attachments `history-row` and `history-archived` show them.
- **Upgrade from v1.** Follow **Upgrade proofs** in the skill, then run `sim.mjs test <run id> UpgradeHistoryProof`. The chat opens on the welcome with no reset notice, History lists two `Earlier chat` rows with the week question and the remember message, and a row opens read-only. Attachments `upgrade-welcome`, `upgrade-history`, and `upgrade-history-read-only` show them.
- **Open time with 50 archived conversations.** Run `sim.mjs test <run id> HistoryOpenProbe/testSeedFiftyResets`, then `sim.mjs test <run id> HistoryOpenProbe/testHistoryOpenWithFiftyArchived`. The attachment `history-open-ms` holds the time from the History tap to the newest row. Run `sim.mjs test <run id> HistoryOpenProbe/testHistoryOpenWithNoneArchived` on a fresh launch for `history-open-empty-ms`, the same tap with nothing archived. The rule: 50 archived conversations open no more than 1 second slower than an empty History, measured at a 1-minute load under 20. `HistoryOpenTests` in the package checks that reading 50 archived conversations over SwiftData takes under 1 second.

## Gotchas

- `sim.mjs launch <run id>` wipes the fixture state and empties History. `sim.mjs launch <run id> --keep` keeps the rows.
- A row identifier ends in the conversation's boundary ULID, or in the chat id for a v1 chat and for the first conversation. Match it with the prefix `history.row.`.
- The date is the fixture's fixed day `1998-06-15`, not the simulator's date.
- History reloads each time the screen appears.
- The History sheet covers the chat, and the chat's controls stay in the accessibility tree behind it. Assert `chat.composer` and `chat.send` are not hittable, not that they are missing.
- A conversation with no messages, such as two resets in a row, is not listed.
