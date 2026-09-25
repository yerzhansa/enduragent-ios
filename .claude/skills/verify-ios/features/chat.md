# Chat

The athlete writes to the coach in the composer, sees the message and the coach's reply in the transcript, opens the slash-command list by typing `/`, and starts over with `New chat`.

## Sub-features

- `chat-greeting` shows `Hello, Ada.`, or `Hello.` after a skipped connect, above an empty transcript, with the disclaimer `Not medical advice, and not a substitute for a doctor or a certified coach.` under the composer.
- `chat-send` posts the athlete's message and clears the composer.
- `chat-reply` shows the coach's reply under the message.
- `chat-working` shows `Coach is working…` in `chat.working` while the turn has no reply text yet.
- `chat-streaming` shows the reply growing while the coach is still answering. Today the working row disappears as soon as the first word arrives; M1-03 keeps it visible until the reply finishes.
- `chat-failed` shows `The coach couldn't respond. Please try again.` in `chat.error` when the model fails, with no Swift type name.
- `chat-relaunch` reopens on the chat with the transcript after the app is killed and relaunched with the kept store.
- `chat-review` answers `/review` with the Saturday group ride.
- `chat-slash-list` lists `/review`, `/status`, `/workout`, and `/language` above the composer, and never `/plan`.
- `chat-slash-fill` fills the composer with the chosen command and a space, which hides the list.
- `chat-plan` answers `/plan` with `Plans arrive in the next TestFlight.` in `chat.error` and adds nothing to the transcript.
- `chat-new` clears the transcript back to the greeting.
- `chat-no-network` keeps `fixture.requestCount` at `0 requests` through every turn.

## How to get to it (user POV)

- Finish onboarding. The chat opens.
- Tap `Message`, type, and choose `Send`.
- Type `/` as the first character in `Message`.
- Choose `New chat` in the top bar.
- Choose `Menu`, then `Debug`, to read the request count.

## Driving it with sim.mjs and XCUITest

Preconditions:

- `sim.mjs doctor <run id>` exits 0 and the app is installed.
- For interactive steps, the app is on the chat after onboarding, reached by the interactive steps in [onboarding.md](./onboarding.md).

- **Send and reply.** Send `What did my training look like this week?`, then `Remember that I ride with a group on Saturdays`. Run `sim.mjs test <run id> FirstConversationProof`. The transcript shows each message, a reply containing `Tuesday sweet spot` and `Training Load`, and `Noted. I'll remember you ride with a group on Saturdays.` Attachment `04-first-conversation` shows the transcript.
- **Review command.** Send `/review`. Run `sim.mjs test <run id> ReviewProof`. The reply contains `Saturday group ride` and `Training Load`. Attachment `05-review` shows it.
- **Slash list.** Tap `chat.composer` and type `/`. Run `sim.mjs test <run id> SlashListNoPlanProof`. `chat.slash.review`, `chat.slash.status`, `chat.slash.workout`, and `chat.slash.language` exist, and `chat.slash.plan` does not. Attachment `slash-list-no-plan` shows the list.
- **Fill from the list.** This step is interactive. With the list open, tap `chat.slash.status`. The composer reads `/status ` and the list disappears. Capture it with `sim.mjs shot <run id> slash-filled`.
- **Plan command.** This step is interactive. Type `/plan` and tap `chat.send`. `chat.error` reads `Plans arrive in the next TestFlight.`, no `/plan` message appears in the transcript, the composer still reads `/plan`, and the slash list stays open. Capture it with `sim.mjs shot <run id> plan-refused`.
- **New chat.** This step is interactive. After a reply, tap the `New chat` button. The transcript returns to the greeting and the composer is empty. Capture it with `sim.mjs shot <run id> new-chat`.
- **No network.** Tap `chat.sidebar`, then `sidebar.debug`. `fixture.requestCount` reads `0 requests`. Capture it with `sim.mjs shot <run id> request-count`. `FirstConversationProof` asserts the same value.
- **Working and streaming.** Send `fixture:slow`. Run `sim.mjs test <run id> SlowReplyProof`. Attachment `slow-reply-working` shows `Coach is working…` with no reply text, `slow-reply-streaming` shows part of the week summary with the working row already gone, and `slow-reply-done` shows the whole reply. Interactively, send `fixture:slow` and take `sim.mjs shot <run id> working` within one second and `sim.mjs shot <run id> streaming` at about three seconds.
- **Failed reply.** Send `fixture:fail 500`. Run `sim.mjs test <run id> FailedReplyProof`. `chat.error` reads `The coach couldn't respond. Please try again.` and nothing on screen names `OpenRouterHTTPError`. Attachment `failed-reply` shows it. `fixture:fail 429 7`, `fixture:fail network`, `fixture:fail timeout`, `fixture:fail overflow`, and `fixture:fail finish` fail the next request with the matching error.
- **Hang and watchdog.** Send `fixture:hang`. Run `sim.mjs test <run id> HangWatchdogProof`. `chat.working` shows for 30 seconds, then `chat.error` reads `The coach couldn't respond. Please try again.` and the working row is gone. Attachments `hang-working` and `hang-watchdog` show both states. Interactively, send `fixture:hang`, wait 35 seconds, and capture with `sim.mjs shot <run id> hang-watchdog`.
- **Storage fault.** Send `fixture:storage fail-next-append`, then `What did my training look like this week?`. Run `sim.mjs test <run id> StorageFaultProof`. The directive adds nothing to the transcript. The question's reply streams, then the turn fails when it saves, and `chat.error` shows the `RecordStorageFault` text while the composer stays. After a relaunch with the kept store the chat shows only the greeting, so nothing from the failed turn was saved. Attachments `storage-fault` and `storage-fault-nothing-saved` show both.
- **Relaunch with the kept store.** After a reply, kill and reopen the app with the kept store. Run `sim.mjs test <run id> RelaunchKeepsChatProof`. The chat shows the question and the reply and the notice is not on screen. Attachment `relaunch-keeps-chat` shows it. Interactively, run `sim.mjs launch <run id> --keep` after a reply.

## Gotchas

- The fixture transport answers with no delay unless the message is `fixture:slow`. Only that directive keeps `chat.working` and the streamed text on screen long enough to capture.
- A `fixture:` directive is typed as a message. `fixture:slow`, `fixture:hang`, and `fixture:fail ...` appear in the transcript as the athlete's message. `fixture:storage fail-next-append` does not: it arms the next write and sends nothing.
- `fixture:slow`, `fixture:hang`, and a queued `fixture:fail` apply to that message only. The next plain message answers at once.
- A misspelled directive is not silent. `chat.error` reads `Unknown fixture directive: <message>` and nothing is sent.
- After `fixture:hang`, wait the full 30 seconds. Sending another message before the watchdog fires queues it behind the hung turn.
- Menu, Debug, Records reads the app's production record store, not the fixture store. It is empty on a verify simulator whatever the fixture did. Prove saved or unsaved records through the transcript after `sim.mjs launch <run id> --keep` instead.
- The fixture picks a reply from the message text, and any unmatched text gets the week summary. A wrong prompt still gets a reply, so assert the specific reply text.
- `/status` and `/workout` get the week summary in the fixture, and the command itself appears as the athlete's message. The workout preview needs a message containing `endurance ride`.
- `TutorialHarness.waitForLabel` waits 10 seconds for an exact label before it falls back to a `CONTAINS` match. Replies longer than the expected fragment still pass, but each such wait adds 10 seconds.
- `New chat` has no accessibility identifier. Find it by its label.
- The menu sheet has no close button. Swipe down to dismiss it, twice from the Debug screen.
- Typing `/` into a composer that already has text does not open the list. The list shows only while the composer starts with `/` and has no space.
