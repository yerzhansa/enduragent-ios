# The ongoing conversation

The athlete sends messages into one ongoing conversation. Each turn saves the message before the coach answers, shows working or streamed text, and ends with a reply or a catalog notice. Try again starts another attempt only when it is safe. New conversation archives earlier messages in History; it does not create another selectable ongoing conversation.

## Sub-features

- `chat-welcome` shows `chat.welcome` until the first message, with `/sync` only when intervals.icu is connected. The health disclaimer remains below the composer.
- `chat-send` saves the athlete message before it appears as accepted, then clears the composer. Send is disabled during acceptance, so another tap cannot duplicate that draft.
- `chat-draft` keeps unsent text across relaunch. A failed save leaves the draft and shows `Not sent. Your draft is still here.` in `chat.composer.notSent`.
- `chat-reply` shows the settled reply without a working row. `chat-working` shows `Coach is working…` during collection, queued work, generation, and retry waits. `chat-streaming` keeps that row below the growing reply until settlement.
- `chat-coalesce` joins free-text messages sent inside the default 1.5-second collection window. A message accepted after work starts gets a later turn.
- `chat-stop` stops the running and queued turns when the athlete taps `chat.stop`. A later message can still run. Saved work determines which interruption notice appears and whether Try again is offered.
- `chat-expiry` settles interrupted work when its execution lease expires. The running turn keeps observed partial text; queued turns do not start.
- `chat-finished-away` adds `Finished while the phone was locked.` under a reply completed in the background. It lasts until relaunch. Device notification behavior needs a device check beyond these fixture proofs.
- `chat-failed` displays `chat.turn.notice` and at most one recovery action for that turn. Provider details, status codes, and Swift error names do not belong in these notices.
- `chat-retry` keeps working visible while the coach retries a recoverable failure. Server and network failures allow two retries, timeouts one, rate limits three, and context overflow three. Once reply text or saved work prevents replay, the coach settles instead.
- `chat-saved-unverified` shows the saved-work notice without Try again when information was saved before the response failed. The athlete must send a new message.
- `chat-try-again` answers the same accepted message in a new attempt. It does not add another athlete-message row.
- `chat-relaunch` keeps settled turns and the draft. `chat-accepted-relaunch` marks an accepted but unstarted message as received before close; it waits for Try again.
- `chat-interrupted-relaunch` marks started work interrupted after a process kill. It makes no automatic model request and restores no uncommitted partial reply.
- `chat-unrecovered-relaunch` shows the history-unavailable notice without Try again while recovery cannot read the earlier attempt. A later readable launch settles it.
- `chat-background` keeps the turn running when the app backgrounds and resumes. Backgrounding starts collected work without waiting out the join window.
- `chat-memory-flush` saves learned information after a large conversation, during overflow handling, or when New conversation closes it. Pending work can resume after relaunch without duplicating saved events. It adds no athlete-visible turn.
- `chat-summary` summarizes older whole turns when the prompt budget is exceeded while preserving the visible transcript. Debug can show the summary at the head of the next prompt.
- `chat-review` sends `/review` as a turn. The fixture replies with the Saturday group ride summary.
- `chat-slash-list` lists `/start`, `/workout`, `/status`, `/review`, and `/language` in that order. `chat-slash-fill` fills a selected command followed by a space. `chat-plan` treats `/plan` as ordinary text and omits it from the list.
- `chat-new-conversation` accepts Start new conversation or `/start` without confirmation. It waits behind current work, saves memory, archives earlier turns, and shows the welcome with a result notice. A pending workout review remains pending.
- `chat-overnight-continuity` keeps one conversation across any gap between messages. Only New conversation or `/start` closes it into History.
- `chat-title` localizes the visible title, Chat in English and Conversation in French, with the same preference as the composer and reply language.
- `chat-session-settings` edits four settings through Debug, Conversation & time. A rejected value preserves the stored value; a saved value affects later turns.
- `chat-no-network` keeps `fixture.requestCount` at zero through all fixture work.

| Turn or composer state | Visible notice and action |
| --- | --- |
| Server, network, timeout, or watchdog failure | `The model provider is having trouble — try again in a few minutes.` with Try again. |
| Rejected Credits access | `Your Credits couldn't be used. Restore purchases to continue.` with `chat.turn.restorePurchases`, which opens Credits. |
| Exhausted Credits | `You're out of Credits. Buy more, or switch to your OpenRouter account.` with `chat.turn.buyCredits`, which opens Credits. |
| Rate limited | A duration such as `~7 seconds`, `~2 minutes`, or `about a minute` in the rate-limit sentence. `chat.turn.tryAgain` stays disabled until the wait ends. |
| Bad request, overflow, or exhausted turn budget | `Sorry, something went wrong. Please try again.` with Try again. |
| Unknown or broken provider stream | `The coach couldn't respond. Please try again.` with Try again. |
| Locked keychain | `Unlock your iPhone to continue. Your message is saved.` with Try again under the turn; a coach-wide notice also uses `chat.composer.notice`. |
| No configured access | `Choose how the coach reaches a model to continue.` with `chat.turn.chooseAccessMethod`, which opens the connect step. |
| Rejected OpenRouter account | Sign-in recovery uses `chat.turn.signInAgain` and currently opens the connect step. There is no fixture UI proof for this access method. |
| Information saved, reply unverified | `I saved your information, but couldn't verify my response. Please try again.` with no recovery button. Send a new message. |
| Interrupted without saved work | `This reply stopped before it finished. Nothing was changed.` with Try again. |
| Interrupted after saved work | `This reply stopped before it finished. Some information was saved first.` with no recovery button. |
| Accepted before close, never started | `Received before the app closed. Tap Try again to send it.` in `chat.turn.receivedBeforeClose`, with Try again. |
| Recovery cannot read records | `Conversation history is temporarily unavailable.` with no recovery button. |
| Message save failed | `Not sent. Your draft is still here.` in `chat.composer.notSent`; the message remains unsent. |

New conversation reports `New conversation started.` in `chat.newConversation.notice`. If memory saving was incomplete, it adds `Some recent details may not have been saved to coach memory.` If the boundary could not be confirmed, the prior visible conversation stays and the notice says `We couldn’t confirm whether the new conversation started. Your visible conversation is preserved.`

## How to get to it (user POV)

- Finish onboarding, tap `chat.composer`, type, and tap `chat.send`.
- Type `/` at the beginning of the composer to open the slash list; choose a command and send it.
- Tap Stop responding while work is running, or the recovery action beneath a settled notice.
- Tap Start new conversation in the top bar or send `/start`.
- Relaunch the next morning with the store kept and send another message.
- Choose Menu, Debug, then Records, Leases, or Conversation & time for the corresponding diagnostic view. The [index](./README.md) lists their identifiers.

## Driving it with sim.mjs and XCUITest

Preconditions:

- Follow the [index](./README.md) setup and require a passing doctor. Each proof prepares its fixture state.
- Let `TutorialHarness.exchange` wait for settlement.

### Sending, commands, and records

| Command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> FirstConversationProof` | Week question and memory reminder each receive their expected reply, `04-first-conversation`. |
| `sim.mjs test <run id> ReceivedBeforeReplyProof` | The accepted message and working row appear before the reply, `received`. |
| `sim.mjs test <run id> SlowReplyProof` | Working, partial reply with working, then completed reply, `slow-reply-working`, `slow-reply-streaming`, `slow-reply-done`. |
| `sim.mjs test <run id> CoalesceProof` | Thursday and Friday join one turn; Records has two messages and one claim and settlement, `coalesce`, `coalesce-records`. The proof widens collection to ten seconds for UI taps. |
| `sim.mjs test <run id> DraftSurvivesKillProof` | An unsent draft survives relaunch without a saved message, `draft-survives`. |
| `sim.mjs test <run id> StorageFaultProof` | A failed append leaves the draft and no accepted message, including after relaunch, `storage-fault-not-sent`, `storage-fault-nothing-saved`, `storage-fault-records`. |
| `sim.mjs test <run id> LongRepliesProof` | Four successive turns settle without an old working row reappearing, `long-replies`. |
| `sim.mjs test <run id> ReviewProof` | `/review` yields Saturday group ride and Training Load, `05-review`. |
| `sim.mjs test <run id> SlashListNoPlanProof` | Slash choices exist and `/plan` is absent, `slash-list-no-plan`. |
| `sim.mjs test <run id> PlanFreeTextProof` | `/plan` appears as an ordinary athlete message and receives a reply, `plan-free-text`. |
| `sim.mjs test <run id> RecordsAfterReplyProof` | Debug, Records shows the saved message, claim, and settlement, `records-after-reply`. |
| `sim.mjs test <run id> RecordsClockOrderProof` | Records show unique logical clocks and the message, claim, review, and settlement rows in causal order, `records-clock-order`. |
| `sim.mjs test <run id> SendLatencyProbe` | `send-latency-ms` measures Send to the accepted message. |
| `sim.mjs test <run id> LaunchLatencyProbe/testSeedTwoHundredTurns`, then `sim.mjs test <run id> LaunchLatencyProbe/testLaunchWithTwoHundredTurns` | The kept store has 200 settled turns; `launch-latency-ms` and `launch-with-two-hundred-turns` measure and show relaunch. |

For slash fill, type `/`, tap `chat.slash.status`, and capture `sim.mjs shot <run id> slash-filled`. The composer must read `/status ` and the list must close. This alternate action has no dedicated proof class.

### Failures, notices, and retry waits

| Command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> FailedReplyProof` | Three server failures end in the provider notice and Try again without wire details, `failed-reply`. |
| `sim.mjs test <run id> FailureCopyProof` | Rejected Credits, network failure, and a seven-second rate limit have their catalog notices and actions, `failure-copy-credentials`, `failure-copy-network`, `failure-copy-rate-limited`. |
| `sim.mjs test <run id> FailureNoticesProof` | Timeout, exhausted Credits, and overflow show distinct recovery choices, `failure-timeout`, `failure-exhausted`, `failure-overflow`. |
| `sim.mjs test <run id> FailedNetworkDarkProof` | Network notice in the helper's dark appearance run, `failed-network-dark`. |
| `sim.mjs test <run id> FailNoticeLatencyProbe` | `fail-notice-latency-ms` measures Send through the server retry ladder to the notice; `fail-notice` shows it. |
| `sim.mjs test <run id> RetryLadderProof` | One server failure recovers with no notice; exhausted rate limits end with a notice, `retry-ladder-reply`, `retry-ladder-rate-limited`. |
| `sim.mjs test <run id> NetworkRetryProof` | Two failed requests recover, three fail the turn; fake model count is six across both turns, `network-retry`, `network-exhausted`, `network-requests`. |
| `sim.mjs test <run id> RateLimitWaitProof` | A hinted seven-second wait retains working before success, then four failures exhaust the ladder, `rate-limit-wait`, `rate-limit-wait-reply`, `rate-limit-wait-exhausted`. |
| `sim.mjs test <run id> RateLimitExhaustedProof` | Four rate-limited requests produce one notice, `rate-limit-exhausted`, `rate-limit-exhausted-requests`. |
| `sim.mjs test <run id> RateLimitMinutesProof` | A 90-second hint reads `~2 minutes` and disables Try again, `rate-limit-minutes`. This proof takes several minutes. |
| `sim.mjs test <run id> RateLimitTryAgainOpensProof` | Try again changes from disabled to enabled after the wait, then succeeds, `rate-limit-waiting`, `rate-limit-try-again-open`, `rate-limit-tried-again`. |
| `sim.mjs test <run id> OverflowExhaustedProof` | Four overflow failures plus one memory flush end in a notice, without durable compaction, `overflow-exhausted`, `overflow-exhausted-records`, `overflow-requests`. |
| `sim.mjs test <run id> HangWatchdogProof` | A hung reply stays working, then ends with the provider notice after the watchdog attempts, `hang-working`, `hang-watchdog`, `hang-watchdog-records`. |
| `sim.mjs test <run id> ReplyObservedProof` | Text already shown is recorded and suppresses replay after the watchdog, `observed-text`, `observed-text-records`, `observed-text-timeout`. |
| `sim.mjs test <run id> SavedUnverifiedProof` | A saved memory write followed by failure or Stop offers no Try again, `saved-unverified`, `saved-unverified-records`, `stopped-after-save`. |
| `sim.mjs test <run id> NoticeCopyProof` | Buy Credits and Restore purchases open Credits; saved-work failure has no replay action, `notice-copy-saved-unverified`. |
| `sim.mjs test <run id> AccessNoticeProof` | Missing access opens Connect; locked keychain keeps the message and offers Try again, `access-not-configured-connect`, `access-locked`. |

### Stop, expiry, background, and relaunch

| Command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> StopProof` | Stop preserves partial text with the nothing-changed notice; Records says `interrupted athleteStopped`, `stop`, `stop-records`. |
| `sim.mjs test <run id> StopNoticeProof` | Stop settles running and queued turns with two Try again actions, `stop-running-and-queued`. |
| `sim.mjs test <run id> StopTryAgainProof` | Try again after Stop produces one completed reply and a second claim, `retry-after-stop`, `retry-after-stop-records`. |
| `sim.mjs test <run id> ExpiryProof` | An `expire-after 3` lease interrupts without a tap; Records says `interrupted systemExpired`, `expiry`, `expiry-timing`, `expiry-records`. |
| `sim.mjs test <run id> QueuedExpiryProof` | Expiry interrupts the running and queued turns; the queued one has no reply, `queued-expiry`. |
| `sim.mjs test <run id> ExpiryAfterSaveProof` | Saved work changes the expiry notice and removes Try again, `expiry-after-save`. |
| `sim.mjs test <run id> FinishedWhileAwayProof` | A reply completed in the background has the finished-while-locked marker, `finished-while-away`. |
| `sim.mjs test <run id> BackgroundResumeProof` | Background and resume preserve the reply with no interruption notice, `background-resume`. |
| `sim.mjs test <run id> LeaseReportProof` | Debug, Leases shows the athlete lease and settled progress, `lease-report`. |
| `sim.mjs test <run id> LeaseTourProof` | Stop, queued expiry, and background completion in one walkthrough, `lease-tour`. |
| `sim.mjs test <run id> RelaunchKeepsChatProof` | Completed message and reply reopen without onboarding, `relaunch-keeps-chat`. |
| `sim.mjs test <run id> AcceptSurvivesKillProof` | Accepted but unclaimed work reopens as received before close; Try again starts it once, `accept-kill-reopen`, `accept-kill-try-again-records`. |
| `sim.mjs test <run id> InterruptedAfterKillProof` | A claimed turn reopens interrupted and waits for Try again, `interrupted-after-kill`, `interrupted-after-kill-try-again`. |
| `sim.mjs test <run id> SavedWorkInterruptedProof` | Saved work before the kill reopens without Try again, `saved-work-interrupted`, `saved-work-interrupted-records`. |
| `sim.mjs test <run id> UnrecoveredClaimProof` | An unreadable recovery shows history unavailable without settlement; a later readable launch shows the saved-work interruption, `unrecovered-claim`, `unrecovered-claim-recovered`. |
| `sim.mjs test <run id> QueuedTurnAfterKillProof` | The running turn reopens interrupted; the queued turn says received before close and runs only after its Try again, `queued-turn-after-kill`, `queued-turn-after-kill-try-again`. |
| `sim.mjs test <run id> ObservedReplyKillProof` | A kill after visible text restores the interruption notice with no partial text or automatic model request, `observed-reply-before-kill`, `observed-reply-after-kill`, `observed-reply-after-kill-records`. |

### Memory, New conversation, and overnight continuity

| Command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> FlushSurvivesKillProof` | A partial memory save remains pending; relaunch settles it without another saved event, `flush-pending-before-kill`, `flush-settled-after-relaunch`. |
| `sim.mjs test <run id> SoftFlushGateProof` | Long replies first remain under the memory-save gate, then open it, `soft-gate-holds`, `soft-gate-opens`. |
| `sim.mjs test <run id> DrainAtLaunchProof` | Relaunch settles both pending memory work and an interrupted turn, `drain-at-launch-notice`, `drain-at-launch-records`. |
| `sim.mjs test <run id> SummaryFirstProof` | Records show compaction; later prompts begin `[Previous conversation summary]`, `summary-records`, `summary-first-next-turn`. |
| `sim.mjs test <run id> NewConversationProof` | The toolbar reset archives the old messages, saves memory, and restores the welcome, `new-conversation`, `new-conversation-records`. |
| `sim.mjs test <run id> SlashStartProof` | `/start` opens the same new-conversation path, `slash-start`, `slash-start-records`. |
| `sim.mjs test <run id> NewConversationWorkingProof` | The old conversation shows working while reset memory saving runs, then opens the welcome, `new-conversation-working`. |
| `sim.mjs test <run id> PartialFlushResetProof` | An incomplete save still opens the new conversation with the memory warning, `partial-flush`, `partial-flush-records`. |
| `sim.mjs test <run id> ResetKeepsReviewProof` | A pending workout review survives the reset, `reset-keeps-review`, `reset-keeps-review-records`. |
| `sim.mjs test <run id> OvernightConversationProof/testThirteenHoursLaterContinuesTheConversation` | A turn at 20:00 local and one 13 hours later after a relaunch stay in one conversation; Records show no `windowStart` and History is empty, `m1-15-overnight-continues`, `m1-15-overnight-history`. |
| `sim.mjs test <run id> SessionRejectionProof` | All four invalid values preserve stored settings and write no settings record, `m1-12-rejected`, `m1-12-rejected-last`. |
| `sim.mjs test <run id> RatioAppliesProof` | A 0.05 history ratio causes earlier compaction than the default, `ratio-applies-turns`, `m1-12-ratio-applies`. |

Debug, Conversation & time uses the field names `historyBudgetRatio`, `contextWindowOverride`, `compactionModel`, and `flushModel`. Enter a value in `session.<field>.input`, tap `.save`, and inspect `.stored` and `.outcome`. End typed input with Return so the keyboard does not hide later rows.

## Gotchas

- A plain fixture reply is fast. Use `fixture:slow` for working and streaming captures, `fixture:hang` for the watchdog, `fixture:text-then-hang` for observed reply text, and `fixture:memory-then-hang` for saved work before interruption.
- `fixture:fail <kind>` fails one model request. Exhaustion needs `500 x3`, `network x3`, `timeout x2`, `overflow x4`, or `429 <seconds> x4`. A single retryable failure normally ends with a successful reply.
- Retry waits use real elapsed time even though the fixture date is fixed. A 90-second rate limit takes several minutes to exhaust and keeps Try again disabled after the notice appears.
- `fixture:memory-then-fail` saves memory before the failure; `fixture:teach` saves it and replies. `fixture:long` expands replies enough to reach memory and summary budgets. `fixture:flush-partial` arms the next memory save, including a New conversation save.
- `fixture:storage fail-next-append` fails its own acceptance and remains in the composer. An unknown directive is not sent and shows `chat.error`; turn failures use `chat.turn.notice`.
- A new plain message clears the fixture's pending slow or failure script. To queue behind work, wait for `turnClaim 1` in Records after `fixture:hang` before sending another message.
- Try again on a fixture directive message replays the scripted reply, not the directive. A retried hang can therefore complete.
- `fixture:expire` expires current leases before its own send, then becomes a later turn. `-EnduragentFixtureHost "expire-after N"` expires every lease N seconds after it starts.
- The fixture execution host does not exercise iOS background scheduling, system cancellation UI, or notifications. Record those device paths as unverified by the simulator.
- Killing within the collection window leaves an accepted message. Wait for a claim before testing interrupted work. A process kill loses uncommitted partial text; it differs from a delivered termination notification.
- Use `sim.mjs launch <run id> --keep -EnduragentFixtureRecovery unreadable` only after a claimed turn was killed to reach unreadable recovery.
- Transcript rows are virtualized. Check the newest content or record counts instead of counting every label in a long conversation.
- Records and Leases read when opened or refreshed. Records has `records.refresh`; Leases has a visible Refresh button without an identifier.
- `fixture.historyHead` and `fixture.replyLanguage` show the most recent model request. Inspect them after that turn settles and before another request changes them.
- The default clock is `1998-06-15T08:00:00Z` in Europe/Ljubljana. Use `-EnduragentFixtureClock <instant>` on relaunch to move it; the clock stays fixed during a launch.
- Menu is a sheet without a close button. Dismiss it and wait for `chat.sidebar` to become hittable before interacting with the conversation.
- Unknown stream, rejected OpenRouter account, uncertain New conversation boundary, and some device lifecycle paths have no dedicated fixture UI proof. Keep those gaps explicit when reporting coverage.
