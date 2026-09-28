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
- `preview-expired` omits an expired review after relaunch without writing a review outcome or clearing record.

## How to get to it (user POV)

- Send `Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks` from the conversation.
- Choose Cancel or Add to calendar on the resulting review.
- Change the connected athlete through Menu, Debug, Credentials while a review exists.
- Reopen a kept v1 store containing an unexpired workout review, once connected and once disconnected, to inspect the earlier-version notice.

## Driving it with sim.mjs and XCUITest

Preconditions:

- Follow the [index](./README.md) setup. Approval proofs connect the fixture athlete during onboarding.
- Wait for `chat.preview.add` or `chat.preview.cancel` to become enabled before tapping.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> ConfirmedPreviewProof` | Workout review, Warmup, and the enabled controls in order, `07-confirmed-preview`. |
| `sim.mjs test <run id> AddedToCalendarProof` | `Done — Create workout "Endurance with tempo" on 1998-06-16.`, `07b-added-to-calendar`; `add-to-done-ms` records the delay. |
| `sim.mjs test <run id> DoneLineSurvivesRelaunchProof` | Saved outcome before and after relaunch, `done-before-relaunch`, `done-after-relaunch`. |
| `sim.mjs test <run id> PreviewCancelStaysGoneProof` | Cancel removes the review through another message and relaunch; Records contains `proposalCleared canceled`, `preview-before-cancel`, `preview-canceled-after-next-message`, `preview-canceled-records`. |
| `sim.mjs test <run id> ReviewLanguageProof` | French title, controls, and durable outcome before and after relaunch, `review-french`, `review-french-relaunch`. |
| `sim.mjs test <run id> ReviewCardComposerProof/testKeyboardKeepsReviewRowsAboveTheComposer` | The keyboard opens while a review is visible. Transcript rows and Add stay above the composer, and Send remains hittable, `review-card-composer-keyboard`. |
| `sim.mjs test <run id> ExpiredReviewProof/testAReviewPastTenMinutesIsGoneAfterRelaunchWithNoWrite` | Relaunch eleven minutes after the proposal removes the card without a Done line or write, `review-before-expiry`, `review-expired-after-relaunch`, `review-expired-records`. |
| `sim.mjs test <run id> LegacyReviewNoticeProof/testV1ReviewIsReadOnlyDisconnectedConnectedAndInGerman` | A seeded v1 review has no approval or cancel controls, `v1-review-disconnected`, `v1-review-connected`, `v1-review-german`. Records retains `pendingProposal 1` without `proposalCleared` or `reviewApplied`, `v1-review-records`, `v1-review-german-records`. |
| `sim.mjs test <run id> ConfirmedPreviewDarkProof` | Dark review capture with an asserted luminance bound, `07-confirmed-preview-dark`. |
| `sim.mjs test <run id> DifferentAthleteProof` | A refused replacement preserves the existing connection; confirmed Switch athlete hides review controls, `different-athlete`, `switch-confirmed`. |
| `sim.mjs test <run id> SameAthleteRotationProof` | A replacement for the same athlete preserves review approval, `same-athlete-rotation-added`. |
| `sim.mjs test <run id> ResetKeepsReviewProof` | New conversation leaves the pending review available, `reset-keeps-review`, `reset-keeps-review-records`. |
| `sim.mjs test <run id> NoCrossChatMemoProof` | After approval, a later turn retries its server failure and finishes; the earlier prepared-ride reply remains visible without a failure notice, `no-cross-chat-memo-done`, `no-cross-chat-memo`. |

For the v1 notice, follow the second recipe under [Upgrade proofs](../SKILL.md#upgrade-proofs). Seed a v1 add, edit, and deletion in turn, and run `LegacyReviewNoticeProof` after each. Keep the fixture clock within the review's lifetime. If the required stores are unavailable, record those cases as unverified.

## Gotchas

- The fixture needs text containing `endurance ride`; `/workout` alone produces the week summary.
- The fake intervals.icu client keeps calendar writes in memory. The Done line and Records are the visible evidence because the app has no calendar screen.
- A review expires after ten minutes. A later launch omits the expired review, while a decision on a stale on-screen review shows the expiry notice.
- A review can survive New conversation. It is not a second ongoing conversation.
- A restored v1 review must be unexpired to exercise the earlier-version notice. Connected and disconnected are distinct cases.
- The compact phone can truncate a long workout description. Inspect the visible cards and controls, and preserve the screenshot rather than assuming every step fits.
- The helper selects dark appearance for the dark proof. Interactive captures must restore light appearance afterwards.
- The keyboard proof requires the software keyboard. Also inspect the opaque composer in light and dark appearance after manually scrolling rows under it.
- The fixture clock is fixed for each launch. `ExpiredReviewProof` verifies expiry on relaunch; `SingleProposalReviewsTests.approveWithStaleTokenIsStaleControl` covers a decision on an expired review without a write.
