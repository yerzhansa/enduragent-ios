# Workout preview

When the athlete asks for a workout, the coach proposes it in a `Confirmed preview` card, and the athlete either adds it to the intervals.icu calendar or cancels it.

## Sub-features

- `preview-show` shows the card with the workout description, including `Warmup`, and the buttons `Cancel` and `Add to calendar` in that order.
- `preview-add` writes the workout and shows `Done — Create workout "Endurance with tempo" on 1998-06-16.`
- `preview-cancel` removes the card without writing.
- `preview-dark` shows the same card in dark appearance.

## How to get to it (user POV)

- In the chat, send a workout request that contains `endurance ride`, such as `Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks`.

## Driving it with sim.mjs and XCUITest

Preconditions:

- `sim.mjs doctor <run id>` exits 0 and the app is installed.
- For interactive steps, the app is on the chat after onboarding. Connecting and skipping both work.

- **Show the preview.** Send the workout request. Run `sim.mjs test <run id> ConfirmedPreviewProof`. `chat.preview.add` and `chat.preview.cancel` exist, and the screen shows `Confirmed preview` and `Warmup`. Attachment `07-confirmed-preview` shows the card.
- **Add to calendar.** Tap `chat.preview.add`. Run `sim.mjs test <run id> AddedToCalendarProof`. The transcript shows `Done — Create workout "Endurance with tempo" on 1998-06-16.` Attachment `07b-added-to-calendar` shows it.
- **Cancel.** This step is interactive. Send the workout request, then tap `chat.preview.cancel`. The card disappears and no `Done` line appears. Send `How did Saturday go` and check that the card stays gone. Capture `sim.mjs shot <run id> preview-before-cancel` before the tap, `sim.mjs shot <run id> preview-canceled` after it, and `sim.mjs shot <run id> preview-after-next-message` after the reply.
- **Dark appearance.** Run `sim.mjs test <run id> ConfirmedPreviewDarkProof`. The card shows `Confirmed preview` in dark appearance. Attachment `07-confirmed-preview-dark` shows it. For an interactive capture, run `sim.mjs parity <run id> review-ready dark` with the card on screen.

## Gotchas

- `Cancel` hides the card, but the next message or reopening the chat from History shows it again with both buttons. Observed on 2026-09-25. `Cancel` clears only the view's copy while the coach keeps the proposal. Always send one more message after a cancel, and report `preview-cancel` as failing while the card returns.
- `/workout` alone does not produce a preview in the fixture. Use a message containing `endurance ride`.
- On iPhone 17e the card cuts its description short, so the cooldown step shows as `Cooldown…` or not at all. Observed on 2026-09-25.
- The fake intervals.icu client keeps the written workout in memory, and the app has no calendar screen. The `Done` line is the only observable proof of the write.
- The card's buttons have no disabled state. The prototype disables `Cancel` and `Confirm` until every card and the kept-workouts context are on screen, so check that rule during parity instead of assuming it holds.
