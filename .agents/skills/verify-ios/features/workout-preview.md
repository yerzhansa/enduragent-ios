# Workout review

The coach puts proposed calendar changes in a Workout review in the ongoing conversation. The athlete approves or cancels the review as one decision. A successful approval leaves a saved outcome in the transcript; an unavailable review explains why its controls cannot be used.

## Sub-features

- `preview-show` displays the workout cards with Cancel to the left of Add to calendar. Both controls wait until the review has appeared before they enable.
- `preview-add` applies the review and saves its Done line as `chat.note`. The line survives relaunch and is readable in History after New conversation.
- `preview-cancel` clears the review without writing the workouts. It remains gone after another message and after relaunch.
- `preview-account-changed` replaces approval controls with `chat.preview.notice` when the connected athlete differs from the one the review was prepared for.
- `preview-earlier-version` shows `This workout review is from an earlier version of the app and can no longer be applied.` for an unexpired v1 review. Check create, update, and delete reviews, both connected to intervals.icu and disconnected. The notice uses `review.earlierVersion` in the chosen language, and neither approval nor cancel controls appear.
- `preview-outcome` shows `chat.review.notice` when a decision encounters expiry, a stale review, changed account, unavailable connection, failed write, or uncertain write result.
- `preview-language` localizes the title, buttons, notices, and saved Done line.
- `preview-dark` keeps the review legible in dark appearance.
- `preview-composer` keeps review rows above the opaque composer when the keyboard opens for a plain message. Send stays hittable.
- `preview-unknown-save` shows one pending-save sentence and only Check again. An absent observation adds Cancel and Save approved workout again. A failed calendar read keeps Check again in the same session. A never-approved card has neither approved-save sentence.
- `preview-cancel-unknown` commits a lasting Cancel note without a calendar request, including offline and locked credentials. Fresh reviews work before and after New conversation; the note stays in History.
- `preview-storage-unavailable` retains and disables the previous decision buttons, shows `review.storageUnavailable` once, and keeps Retry enabled. Retry rereads saved records and restores valid controls without a model request or calendar call.
- `preview-choice-save-failed` keeps approval controls available and shows `review.saveFailed` once when Add or Cancel cannot save the choice. The sentence follows the chosen language and no calendar write runs.
- `preview-expired` omits an expired review after relaunch without writing a review outcome or clearing record.

## How to get to it (user POV)

- Send `Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks` from the conversation.
- Choose Cancel or Add to calendar on the resulting review.
- Change the connected athlete through Settings, Debug, Credentials while a review exists.
- Launch the committed `.v1Review` fixture with `TutorialHarness.launchUpgrade`, then inspect the earlier-version notice while disconnected and connected.

## Driving it with sim.mjs and XCUITest

Preconditions:

- Follow the [index](./README.md) setup. Approval proofs connect the fixture athlete during onboarding.
- Wait for `chat.preview.add` or `chat.preview.cancel` to become enabled before tapping.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> UnknownCalendarSaveProof` | Light proofs assert exact sentence counts and review button identifiers and labels for unknown, absent, failed-read, and never-approved states. Attachments start with `calendar-`. |
| `sim.mjs test <run id> UnknownCalendarSaveDarkProof` | The same proofs in dark appearance, with screenshots and an asserted luminance bound. |
| `sim.mjs test <run id> CancelUnknownSaveProof` | Offline and locked Cancel leave one buttonless note after relaunch, allow fresh reviews in both conversations, and keep the original note in History. Screenshots start with `cancel-`. |
| `sim.mjs test <run id> CancelUnknownSaveDarkProof` | The same Cancel proofs in dark appearance, with screenshots and an asserted luminance bound. |
| `sim.mjs test <run id> ReconnectReviewProof` | Peer B replacement removes A's approval controls and requires B's own approval. Rotated A restores the review after relaunch and Check again confirms its unknown save with one read and no second save. Under B, online and offline Cancel make no A/B request, allow an immediate fresh review, and retain the exact button-free note after relaunch. Attachments start with `U5-4-`. |
| `sim.mjs test <run id> SavedReviewReadFailureProof` | Approval, Check again, repeat approval, Cancel only, and read-only layouts retain their labels while disabled. Retry remains enabled after another failed read and restores valid controls without model or calendar requests. Screenshots start with `review-unreadable-` and `review-restored-`. |
| `sim.mjs test <run id> SavedReviewReadFailureDarkProof` | The same saved-review read proofs in dark appearance, with screenshots and an asserted luminance bound. |
| `sim.mjs test <run id> ReviewStorageFailureProof` | Failed Add shows the G22 sentence in English; failed Cancel shows it in French. Each keeps the review, shows one notice, makes no calendar write or model request, and allows a later Cancel. Attachments start with `review-save-failed-`. Saved-review read recovery is owned by `SavedReviewReadFailureProof`. |
| `sim.mjs test <run id> ReviewStorageFailureDarkProof` | The same choice-save failure proofs in dark appearance, with screenshots and an asserted luminance bound. Saved-review read recovery is owned by `SavedReviewReadFailureDarkProof`. |
| `sim.mjs test <run id> ConfirmedPreviewProof` | Workout review, Warmup, and the enabled controls in order, `07-confirmed-preview`. |
| `sim.mjs test <run id> AddedToCalendarProof` | `Done — Create workout "Endurance with tempo" on 1998-06-16.`, `07b-added-to-calendar`; `add-to-done-ms` records the delay. |
| `sim.mjs test <run id> DoneLineSurvivesRelaunchProof` | Saved outcome before and after relaunch, `done-before-relaunch`, `done-after-relaunch`. |
| `sim.mjs test <run id> PreviewCancelStaysGoneProof` | Cancel removes the review through another message and relaunch; Records contains `proposalCleared canceled`, `preview-before-cancel`, `preview-canceled-after-next-message`, `preview-canceled-records`. |
| `sim.mjs test <run id> ReviewLanguageProof ReviewLanguageDarkProof` | A saved pending cycling review reopens in French with French regional decimals, repetitions, cadence, and an unchanged copied label. Approval leaves a durable outcome that follows a later English choice in conversation and History. Attachments start `u9-4-review-reopened-fr-`, `u9-4-outcome-reopened-fr-`, and `u9-4-history-outcome-en-`, with light and dark suffixes. Each theme asserts its luminance. |
| `sim.mjs test <run id> ReviewCardComposerProof/testKeyboardKeepsReviewRowsAboveTheComposer` | The keyboard opens while a review is visible. Transcript rows and Add stay above the composer, and Send remains hittable, `review-card-composer-keyboard`. |
| `sim.mjs test <run id> ExpiredReviewProof/testAReviewPastTenMinutesIsGoneAfterRelaunchWithNoWrite` | Relaunch eleven minutes after the proposal removes the card without a Done line or write, `review-before-expiry`, `review-expired-after-relaunch`, `review-expired-records`. |
| `sim.mjs test <run id> LegacyReviewNoticeProof/testV1ReviewIsReadOnlyDisconnectedConnectedAndInGerman` | The committed v1 review has no approval or cancel controls, `v1-review-disconnected`, `v1-review-connected`, `v1-review-german`. Records retains `pendingProposal 1` without `proposalCleared` or `reviewApplied`, `v1-review-records`, `v1-review-german-records`. |
| `sim.mjs test <run id> ConfirmedPreviewDarkProof` | Dark review capture with an asserted luminance bound, `07-confirmed-preview-dark`. |
| `sim.mjs test <run id> DifferentAthleteProof` | A refused replacement preserves the existing connection; confirmed Switch athlete hides review controls, `different-athlete`, `switch-confirmed`. |
| `sim.mjs test <run id> SameAthleteRotationProof` | A replacement for the same athlete preserves review approval, `same-athlete-rotation-added`. |
| `sim.mjs test <run id> ResetKeepsReviewProof` | New conversation leaves the pending review available, `reset-keeps-review`, `reset-keeps-review-records`. |
| `sim.mjs test <run id> NoCrossChatMemoProof` | After approval, a later turn retries its server failure and finishes; the earlier prepared-ride reply remains visible without a failure notice, `no-cross-chat-memo-done`, `no-cross-chat-memo`. |

For the v1 notice, follow [Upgrade proofs](../SKILL.md#upgrade-proofs). `LegacyReviewNoticeProof` copies the committed `.v1Review` stores before launch and must pass with zero skips. It checks the create review while disconnected, connected, and in German. Package migration tests cover v1 edit and deletion reviews. Keep the fixture clock within the review's lifetime. A missing committed store is a failure.

## Gotchas

- The fixture needs text containing `endurance ride`; `/workout` alone produces the week summary.
- `fixture.failNextAppend` fails the next record append. Arm it through `TutorialHarness.fixtureControl` in Settings > Debug after the review is presented and the proposing turn has settled, then tap Add or Cancel. Reach every Debug row through `TutorialHarness.debugRow`, and use `TutorialHarness.returnToChat` to leave Settings or the language picker.
- `FixtureArguments(calendarSaveFault: .loseAnswerOnce)` stores the full approval under its UID before losing the answer. `calendarReadFault: .failOnce` affects only the next event list or event fetch. Relaunch with `.keep` retains the unknown write records and opens an empty fake calendar for the absent-read proof. The record-read launch hook waits for a presented, settled card. Settings > Debug controls, reached with `fixtureControl`, arm the same read fault for other layouts. Retry restores controls without checking the calendar.
- The fake intervals.icu client keeps calendar writes in memory. The Done line and Records are the visible evidence because the app has no calendar screen.
- `ReconnectReviewProof` reuses the peer controls and unknown-save fixture. The peer receipt includes separate A/B calendar-call and profile-read counts. `fixture.failCalendarRead` arms both athletes; the fault stays armed through Cancel and a fresh review while connected to B. Same-athlete read-back runs before another relaunch because the fake calendar is held in memory.
- A review expires after ten minutes. A later launch omits the expired review, while a decision on a stale on-screen review shows the expiry notice.
- A review can survive New conversation. It is not a second ongoing conversation.
- A restored v1 review must be unexpired to exercise the earlier-version notice. Connected and disconnected are distinct cases.
- The compact phone can truncate a long workout description. Inspect the visible cards and controls, and preserve the screenshot rather than assuming every step fits.
- The helper selects dark appearance for the dark proof. Interactive captures must restore light appearance afterwards.
- The keyboard proof requires the software keyboard. Also inspect the opaque composer in light and dark appearance after manually scrolling rows under it.
- The fixture clock is fixed for each launch. `ExpiredReviewProof` verifies expiry on relaunch; `SingleProposalReviewsTests.approveWithStaleTokenIsStaleControl` covers a decision on an expired review without a write.
