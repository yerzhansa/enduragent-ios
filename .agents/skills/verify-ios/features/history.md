# History

History contains archived conversations and opens each one read-only. There is still only one ongoing conversation. New conversation closes earlier messages into History; a v1 upgrade exposes earlier chats as archived conversations.

## Sub-features

- `history-empty` shows `No past conversations yet. Starting a new conversation keeps the old one here.` when nothing has been archived.
- `history-list` lists archived conversations newest first under the catalog title `History`, shared with the toolbar action. Rows show the first athlete message, close reason, and start day.
- `history-athlete-ownership` shows no athlete line before this phone connects two distinct athletes. Afterwards a conversation wholly saved for another verified athlete shows one `Saved for another intervals.icu athlete ({{id}})` line with its saved ID. Mixed and unrecoverable conversations show no line.
- `history-reasons` shows `You started a new conversation` or `Earlier chat` for New conversation or v1 content respectively.
- `history-archived` opens `Past conversation` with the saved turns in `archive.content` and the workout review outcome lines in `archive.note`, such as `Endurance with tempo, 6/16/1998: change saved.` `archive.readOnly` says `Past conversations are read-only.` There is no active composer or recovery action in the archived content. A review carried into the new conversation and approved there leaves its line in the current conversation, not the archive. No UI proof reads `archive.note`; package `ReviewOutcomeNotesTests.aCompletedReviewsNoteShowsEveryChangeAfterRefreshReopenNewConversationAndRelaunch` proves the lines after New conversation.
- `history-formatted` uses the same reply renderer as Chat, including dimmed stopped text and the whole-source parser fallback.
- `history-upgrade` puts v1 chats in History and opens the ongoing conversation on the welcome.
- `history-unavailable` shows `Past conversations are temporarily unavailable.` if the list cannot be read. An archive that cannot be read shows `This conversation is temporarily unavailable.`, and one that no longer exists shows `This conversation is no longer available.` Opening History starts no model request and runs no pending memory work.
- `history-language` renders the empty list, the saved-athlete line, the archive title and the read-only notice in the language preference. `LanguageMatrix` `testHistory` on the [language page](./language.md) captures them.

## How to get to it (user POV)

- Tap the toolbar History icon from the ongoing conversation.
- Tap a `history.row.<id>` to read an archived conversation.
- Create an archive with the compose icon labeled New conversation or `/start`. The [conversation map](./chat.md) covers those paths.

## Driving it with sim and XCUITest

Preconditions:

- Follow the [index](./README.md) setup. Upgrade proofs copy the committed v1 stores at launch, as the Upgrade proofs paragraph of the verify-ios skill describes.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim test <run id> AthleteOwnershipProof` | Before a peer replacement, after it and after relaunch, History shows the exact saved-athlete line only where appropriate. Add on the retained review shows the athlete-changed sentence and leaves Cancel alone, which stays after relaunch. Attachments start with `u5-3-` and cover the conversation, review, History and unverified archive. |
| `sim test <run id> HistoryListProof` | History is empty after the first reply; `/start` creates one row, `history-empty`, `history-list`. |
| `sim test <run id> ReplyFormattingProof ReplyTableProof ReplyStreamingStoppedProof ReplyFallbackProof` | A New conversation archive preserves formatted replies, table row labels, stopped prefixes and the literal fallback. The [conversation map](./chat.md) names the attachments and parity procedure. |
| `sim test <run id> HistoryArchivedProof` | The toolbar reset creates a row; opening it shows the prior question, reply, and read-only notice, `history-row`, `history-archived`. |
| `sim test <run id> UpgradeHistoryProof` | Two v1 rows read Earlier chat; one opens read-only, `upgrade-welcome`, `upgrade-history`, `upgrade-history-read-only`. A missing store fails the proof. |
| `sim test <run id> HistoryOpenProbe/testSeedFiftyResets`, then `sim test <run id> HistoryOpenProbe/testHistoryOpenWithFiftyArchived` | The kept store has 50 archives; `history-open-ms` measures opening them and `history-with-fifty-archived` shows the list. |
| `sim test <run id> HistoryOpenProbe/testHistoryOpenWithNoneArchived` | A fresh store supplies the empty baseline, `history-open-empty-ms`. |

Compare the 50-archive and empty measurements under a one-minute load below 20. The acceptance bound is no more than one additional second for 50 archives. Do not loosen it after a load-related failure. The package test for History read failure supplies the unavailable case; there is no UI fixture directive for that read failure.

## Gotchas

- Fresh launch erases the fixture archives. Use a kept store between a seed and its measurement.
- Match the `history.row.` prefix. Its suffix is the boundary identifier or the earlier conversation identifier, not a stable sequence number.
- The fixture date is 1998-06-15 unless the proof supplies another clock instant.
- History reloads when it appears. It does not provide an action to resume an archived conversation.
- History pushes onto the conversation navigation stack. The ongoing conversation controls must not be hittable while reading an archive.
- Consecutive resets with no messages do not create empty History rows.
- In fixture launches Settings > Debug has the peer controls `fixture.peerA`, `fixture.switchAthlete`, `fixture.peerRotateA`, `fixture.peerReject`, `fixture.peerUnavailable`, `fixture.peerDelete`, `fixture.peerHoldProfile`, `fixture.peerReleaseProfile` and `fixture.peerReceipt`, with a failure in `fixture.peerFailure`. Reach every row with `TutorialHarness.debugRow`. They change only the shared item or the fake profile gate; Resume, Send and approval drive the real current-connection check. The file-backed peer and the native peer use the same fake service routing. `AthleteOwnershipProof` taps `fixture.switchAthlete`, then `fixture.seedOwnership` and reads `fixture.ownershipSeedResult`. The [two-phone reconnect check](../phone.md#prove-reconnect-across-two-phones) uses `fixture.peerA`, `fixture.peerDelete` and `fixture.peerReceipt`. No test taps the other peer rows.
