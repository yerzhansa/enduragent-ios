# Workout preview

When the athlete asks for a workout, the coach proposes it in a `Workout review` card, and the athlete either adds it to the intervals.icu calendar or cancels it. The card is the chat's `ReviewSnapshot`, and every button sends one `ReviewDecision` to `Coach.decide`, which never waits behind a running reply and never asks the model.

## Sub-features

- `preview-show` shows the card with the workout description, including `Warmup`, and the buttons `Cancel` and `Add to calendar` in that order. Both stay disabled until the card reports that it is on screen.
- `preview-add` writes the workout and shows `Done — Create workout "Endurance with tempo" on 1998-06-16.` in the transcript as `chat.note`. The line is a synced `reviewApplied` record, so it is still there after a relaunch and appears in History after New conversation.
- `preview-cancel` removes the card without writing. It records `proposalCleared` with the reason `canceled`, so the card does not come back on the next message or after a relaunch.
- `preview-account-changed` replaces both buttons with `chat.preview.notice` when the card was prepared for a different intervals.icu athlete than the one connected now.
- `preview-earlier-version` shows `chat.preview.notice` in the Chat screen's `Workout review` card for a restored, unexpired v1 `pendingProposal`, whether it adds, edits, or deletes a workout. Check both an intervals.icu-connected athlete and a disconnected athlete. The notice reads `This workout review is from an earlier version of the app and can no longer be applied.` through `review.earlierVersion` in the selected language, and neither `chat.preview.cancel` nor `chat.preview.add` appears.
- `preview-outcome` shows the result of a tap that did not add the workout in `chat.review.notice`: the expired sentence for an expired or stale card, the account-changed sentence, a connection sentence when the Keychain cannot be read, or an intervals.icu sentence when the write failed or its result is unknown.
- `preview-dark` shows the same card in dark appearance.

## How to get to it (user POV)

- In the chat, send a workout request that contains `endurance ride`, such as `Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks`.

## Driving it with sim.mjs and XCUITest

Preconditions:

- `sim.mjs doctor <run id>` exits 0 and the app is installed.
- For interactive steps, the app is on the chat after onboarding. Connecting and skipping both work.

The review proofs live in `apps/ios/EnduragentUITests/ReviewProofs.swift`.

- **Show the preview.** Run `sim.mjs test <run id> ConfirmedPreviewProof`. `chat.preview.add` and `chat.preview.cancel` become enabled, `Cancel` sits left of `Add to calendar`, and the screen shows `Workout review` and `Warmup`. Attachment `07-confirmed-preview` shows the card.
- **Add to calendar.** Run `sim.mjs test <run id> AddedToCalendarProof`. The transcript shows `Done — Create workout "Endurance with tempo" on 1998-06-16.` Attachment `07b-added-to-calendar` shows it, and the string attachment `add-to-done-ms` holds the time from the tap to the line.
- **The Done line survives a relaunch.** Run `sim.mjs test <run id> DoneLineSurvivesRelaunchProof`. Attachments `done-before-relaunch` and `done-after-relaunch` show the line before and after a relaunch that keeps the store.
- **Chosen language.** Run `sim.mjs test <run id> ReviewLanguageProof`. The card title, buttons, and saved Done line render in French after `/language` selects French, and the Done line remains French after relaunch. Attachments `review-french` and `review-french-relaunch` show both states.
- **Cancel.** Run `sim.mjs test <run id> PreviewCancelStaysGoneProof`. It taps `chat.preview.cancel`, sends `How did Saturday go`, relaunches, and opens Records. Attachments `preview-before-cancel`, `preview-canceled-after-next-message`, and `preview-canceled-records` show the card, the chat without it after the reply, and Records with `proposalCleared 1` and a `proposalCleared canceled` row.
- **Account changed.** Send the workout request, then Menu, Debug, Credentials, type `other-athlete` in `credentials.apiKey`, and tap `credentials.switchAthlete`. Back in the chat, the card shows `chat.preview.notice` reading `This workout was prepared for a different intervals.icu athlete. Ask me again to prepare it for the connected athlete.` and has no `chat.preview.add`.
- **Dark appearance.** Run `sim.mjs test <run id> ConfirmedPreviewDarkProof`. `sim.mjs test` runs it in dark appearance, and the proof asserts that its capture is dark, so a run that did not switch the simulator fails instead of passing on a light screen. Attachment `07-confirmed-preview-dark` shows the card. For an interactive capture, run `xcrun simctl ui <udid> appearance dark`, then `sim.mjs parity <run id> review-ready dark` with the card on screen, then set the appearance back to `light`.

## Gotchas

- `/workout` alone does not produce a preview in the fixture. Use a message containing `endurance ride`.
- On iPhone 17e the card cuts its description short, so the cooldown step shows as `Cooldown…` or not at all. Observed on 2026-09-25.
- The fake intervals.icu client keeps the written workout in memory, and the app has no calendar screen. The `Done` line and Debug, Records are the observable proof of the write.
- A card expires 10 minutes after the coach proposed it. After that, a launch shows no card, and a tap on a card still on screen shows `That proposal expired — ask me again and I'll re-propose.` in `chat.review.notice`.
- The buttons enable when the card appears on screen. A proof must wait for `enabled == true` before it taps, as `TutorialHarness.waitUntilEnabled` does, or the tap lands on a disabled button and does nothing.
