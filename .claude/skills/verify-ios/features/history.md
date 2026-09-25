# History

The menu's History screen lists the chats started so far, newest first, each titled with its first message and dated with its start day. Choosing a row reopens that chat.

## Sub-features

- `history-list` shows one `history.row.<chat id>` row per chat with its title and `1998-06-15`.
- `history-untitled` titles a chat with no messages `New chat`.
- `history-open` reopens the chosen chat and closes the menu.

## How to get to it (user POV)

- In the chat, choose `Menu`, then `History`.

## Driving it with sim.mjs and XCUITest

Preconditions:

- `sim.mjs doctor <run id>` exits 0 and the app is installed.
- For interactive steps, the app is on the chat after onboarding and at least one message has a reply.

- **List.** Send `What did my training look like this week?`, then tap `chat.sidebar` and `sidebar.history`. Run `sim.mjs test <run id> HistoryListProof`. A row whose identifier starts with `history.row.` shows `What did my training look like this week?` and `1998-06-15`. Attachment `history-list` shows it.
- **Untitled chat.** This step is interactive. Dismiss the menu, tap `New chat`, then open `Menu` and `History`. Two rows appear, and the newest one reads `New chat`. Capture it with `sim.mjs shot <run id> history-two-chats`.
- **Reopen.** This step is interactive. Tap the row titled `What did my training look like this week?`. The menu closes and the transcript shows that question and its reply. Capture it with `sim.mjs shot <run id> history-reopened`.

## Gotchas

- `sim.mjs launch <run id>` wipes the fixture state and empties History. `sim.mjs launch <run id> --keep` keeps the rows.
- The row identifier ends in a random chat id. Match it with the prefix `history.row.`, as `HistoryListProof` does.
- The date is the fixture's fixed day `1998-06-15`, not the simulator's date.
- History reloads each time the screen appears. Leave it and open it again to see a new chat.
