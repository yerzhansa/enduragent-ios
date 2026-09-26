# Chat

The athlete writes to the coach in the composer, sees the message and the coach's reply in the transcript, opens the slash-command list by typing `/`, and starts over with `New chat`.

## Sub-features

- `chat-greeting` shows `Hello, Ada.`, or `Hello.` after a skipped connect, above an empty transcript, with the disclaimer `Not medical advice, and not a substitute for a doctor or a certified coach.` under the composer.
- `chat-send` saves the athlete's message before the model runs, shows it in the transcript the moment Send is tapped, and clears the composer.
- `chat-draft` keeps typed, unsent text in the composer across a kill and relaunch, and shows `Not sent. Your draft is still here.` in `chat.composer.notSent` when the message could not be saved.
- `chat-reply` shows the coach's reply under the message.
- `chat-working` shows `Coach is working…` in `chat.working` under the message while the turn has no reply text yet.
- `chat-streaming` shows the reply growing under the message with the working row staying under the reply text while the coach is still answering.
- `chat-stop` shows `Stop responding` in `chat.stop` while a turn runs; tapping it stops the turn and shows `Response stopped. Your partial response is preserved.` with `Try again`.
- `chat-failed` shows `The coach couldn't respond. Please try again.` in `chat.turn.notice` under the message when the model fails, with a `Try again` button in `chat.turn.tryAgain` and no Swift type name. `chat.error` no longer exists for turns.
- `chat-try-again` answers the same message again under a new attempt; Records lists one more `turnClaim` and the turn's `turnSettled`.
- `chat-relaunch` reopens on the chat with the transcript after the app is killed and relaunched with the kept store.
- `chat-accepted-relaunch` shows a message that was sent but never answered before the app closed once, with `Received before the app closed. Tap Try again to send it.` in `chat.turn.receivedBeforeClose` and `Try again`; nothing runs until the tap.
- `chat-coalesce` joins two free-text messages sent within 1.5 seconds into one turn whose athlete text has both lines; Records lists `userMessage 2` with one turn.
- `chat-review` answers `/review` with the Saturday group ride.
- `chat-slash-list` lists `/review`, `/status`, `/workout`, and `/language` above the composer, and never `/plan`.
- `chat-slash-fill` fills the composer with the chosen command and a space, which hides the list.
- `chat-plan` sends `/plan` to the coach as an ordinary message; the fixture answers with the week summary.
- `chat-new` clears the transcript back to the greeting.
- `chat-no-network` keeps `fixture.requestCount` at `0 requests` through every turn.

## How to get to it (user POV)

- Finish onboarding. The chat opens.
- Tap `Message your coach`, type, and choose `Send message`.
- Type `/` as the first character in `Message your coach`.
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
- **Plan command.** This step is interactive. Type `/plan` and tap `chat.send`. `/plan` appears as the athlete's message and the week summary follows. Capture it with `sim.mjs shot <run id> plan-sent`.
- **New chat.** This step is interactive. After a reply, tap the `New chat` button. The transcript returns to the greeting and the composer is empty. Capture it with `sim.mjs shot <run id> new-chat`.
- **No network.** Tap `chat.sidebar`, then `sidebar.debug`. `fixture.requestCount` reads `0 requests`. Capture it with `sim.mjs shot <run id> request-count`. `FirstConversationProof` asserts the same value.
- **Working and streaming.** Send `fixture:slow`. Run `sim.mjs test <run id> SlowReplyProof`. Attachment `slow-reply-working` shows `Coach is working…` under the message with no reply text, `slow-reply-streaming` shows part of the week summary with the working row still under it, and `slow-reply-done` shows the whole reply with the working row gone. Interactively, send `fixture:slow` and take `sim.mjs shot <run id> working` within one second and `sim.mjs shot <run id> streaming` at about three seconds.
- **Failed reply and Try again.** Send `fixture:fail 500`. Run `sim.mjs test <run id> FailedReplyProof`. `chat.turn.notice` reads `The coach couldn't respond. Please try again.` with `chat.turn.tryAgain` under it, `chat.error` does not exist, and nothing on screen names `OpenRouterHTTPError`. Attachment `failed-reply` shows it. Tapping `chat.turn.tryAgain` answers the message with the week summary. `fixture:fail 429 7`, `fixture:fail network`, `fixture:fail timeout`, `fixture:fail overflow`, and `fixture:fail finish` fail the next request with the matching error.
- **Hang and watchdog.** Send `fixture:hang`. Run `sim.mjs test <run id> HangWatchdogProof`. `chat.working` shows for 30 seconds after the 1.5 second window, then `chat.turn.notice` reads `The coach couldn't respond. Please try again.` with `Try again`, the working row is gone, and `chat.error` does not exist. Attachments `hang-working` and `hang-watchdog` show both states. Interactively, send `fixture:hang`, wait 35 seconds, and capture with `sim.mjs shot <run id> hang-watchdog`.
- **Received before the reply.** Send `What did my training look like this week?`. Run `sim.mjs test <run id> ReceivedBeforeReplyProof`. Attachment `received` shows the message with `Coach is working…` under it and no reply text, taken inside the 1.5 second window. `SendLatencyProbe` times the Send tap to the message on screen and attaches the milliseconds as `send-latency-ms`.
- **Send, kill, reopen, Try again.** Send `fixture:hang`, terminate the app, and relaunch with the kept store. Run `sim.mjs test <run id> AcceptSurvivesKillProof`. Before the kill the proof waits in Records until `turnClaim 1` shows, so the model call is hanging when the app dies. Attachment `accept-kill-reopen` shows the message once with `Received before the app closed. Tap Try again to send it.` and `Try again`, `accept-kill-records` lists `userMessage 1` and `turnClaim 1` with no `turnSettled`, and `accept-kill-try-again` shows the week summary after the tap with `turnClaim 2` and `turnSettled 1`. Interactively, send `fixture:hang`, run `sim.mjs launch <run id> --keep`, and tap `chat.turn.tryAgain`.
- **Storage fault.** Send `fixture:storage fail-next-append`. Run `sim.mjs test <run id> StorageFaultProof`. The directive itself is the message that fails to save: the composer keeps the text, `chat.composer.notSent` reads `Not sent. Your draft is still here.`, and the transcript does not change. After a relaunch with the kept store the composer still holds the text and Records lists no `userMessage`. Attachments `storage-fault-not-sent`, `storage-fault-nothing-saved`, and `storage-fault-records` show it.
- **Stop.** This step is interactive. Send `fixture:slow`, wait about three seconds, and tap `chat.stop`. The streamed text stays dimmed under the message with `Response stopped. Your partial response is preserved.` and `Try again`. Capture it with `sim.mjs shot <run id> stopped`.
- **Coalescing.** Send `Thursday?` and then `Friday?` within 1.5 seconds. Run `sim.mjs test <run id> CoalesceProof`. The transcript shows one turn whose athlete text has both lines and one reply, and Records lists `userMessage 2`, `turnClaim 1`, and `turnSettled 1`. Attachments `coalesce` and `coalesce-records` show it.
- **Draft survives.** Type `Is Thursday still on?`, do not send, and relaunch with the kept store. Run `sim.mjs test <run id> DraftSurvivesKillProof`. The composer holds the typed text, the transcript shows only the greeting, and Records lists no `userMessage`. Attachment `draft-survives` shows it.
- **Relaunch with the kept store.** After a reply, kill and reopen the app with the kept store. Run `sim.mjs test <run id> RelaunchKeepsChatProof`. The chat shows the question and the reply and the notice is not on screen. Attachment `relaunch-keeps-chat` shows it. Interactively, run `sim.mjs launch <run id> --keep` after a reply.

## Gotchas

- The fixture transport answers with no delay unless the message is `fixture:slow`. Only that directive keeps `chat.working` and the streamed text on screen long enough to capture.
- A `fixture:` directive is typed as a message. `fixture:slow`, `fixture:hang`, and `fixture:fail ...` appear in the transcript as the athlete's message. `fixture:storage fail-next-append` arms the record store before its own save, so it is the message that fails and stays in the composer.
- `fixture:slow` and `fixture:hang` apply to that message only. The next plain message answers at once. `Try again` on a directive message replays only the scripted reply, never the directive, so a retried `fixture:hang` answers with the week summary.
- Every send waits 1.5 seconds for a second message to join the same turn before the coach starts. Replies arrive that much later than the tap.
- A misspelled directive is not silent. `chat.error` reads `Unknown fixture directive: <message>`, nothing is sent, and the composer keeps the text.
- After `fixture:hang`, wait the full 30 seconds. Sending another message before the watchdog fires queues it behind the hung turn.
- Menu, Debug, Records reads the store the app writes, including the fixture store, when the screen opens. It does not update by itself; `Refresh` reads it again, and `TutorialHarness.waitForRecordCount` taps it until a count shows.
- The fixture picks a reply from the message text, and any unmatched text gets the week summary. A wrong prompt still gets a reply, so assert the specific reply text.
- `/status` and `/workout` get the week summary in the fixture, and the command itself appears as the athlete's message. The workout preview needs a message containing `endurance ride`.
- `TutorialHarness.waitForLabel` waits 10 seconds for an exact label before it falls back to a `CONTAINS` match. Replies longer than the expected fragment still pass, but each such wait adds 10 seconds.
- `New chat` has no accessibility identifier. Find it by its label.
- The menu sheet has no close button. Swipe down to dismiss it, twice from the Debug screen.
- Typing `/` into a composer that already has text does not open the list. The list shows only while the composer starts with `/` and has no space.
