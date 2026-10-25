# Plan-save card

When the coach saves a training plan with `plan_save`, the turn ends with a small card that asks `Save this training plan?`. The athlete decides with Save plan or Cancel. The card names the plan, its goal and length, one row per phase, and the saved plan it replaces. After a decision it shows Saved, Canceled or Expired and no control. A card that was still waiting at New conversation is drawn once at the top of the next conversation, marked Prepared earlier.

## Sub-features

- `plan-card-show` places the card after the turn that prepared it: a title row (`chat.planSave.title`, and `chat.planSave.preparedEarlier` for a carried card), then the card (`chat.planSave.card`) with the name (`chat.planSave.name`), the goal and length pairs (`chat.planSave.goal.label`/`.value`, `chat.planSave.duration.label`/`.value`), one block per phase (`chat.planSave.phase`, then `focus`, `weeks` and `hours` pairs), the "replaces" line (`chat.planSave.replaces`), the state line (`chat.planSave.state`) and the answer to a refused tap (`chat.planSave.answer`). A field the plan lacks is left out. A plan with no saved plan before it has no "replaces" line. An ended card keeps the line it had when it ended.
- `plan-card-arming` shows no Save plan or Cancel until the card's title has been on screen: half of the title row between the navigation bar and the composer or docked bars. Scrolling the title into view arms the card. A relaunch arms it again only after its title is on screen.
- `plan-card-bar` holds Save plan (`chat.planSave.save`) then Cancel (`chat.planSave.cancel`) in `chat.planSave.bar`, side by side when they fit and stacked otherwise. At the default size the bar is docked above the composer, under the review bar when a workout review also waits. At accessibility sizes it sits in the transcript directly under its card, and the disclaimer is the transcript's last row.
- `plan-card-opening` opens the chat with the newest message and a waiting card's title on screen when that card ends the transcript, at launch and after a relaunch. The transcript keeps the title centred while its rows are measured, until the athlete drags it or another scroll (the keyboard, the slash list) takes over. When newer turns follow a carried card, the newest message wins.
- `plan-card-states` shows waiting (Save plan and Cancel), saving (`Saving the plan…`), saved (`Saved. This is now your training plan.`), canceled (`Canceled. This plan was not saved.`), expired (`Expired. Ask the coach again to save this plan.`) and storage unavailable (`This plan could not be saved because storage on this iPhone is unavailable.`). Only waiting has controls.
- `plan-card-refusals` answers a refused tap on the card: `Not saved: the ten minutes to save this plan have passed.` (the card reads Expired, no control), `Not saved: a newer plan is waiting to be saved.` (the older card reads Expired, no control; the newer card waits under its own turn), `This plan was already saved or canceled.` (the card keeps Saved or Canceled, no control) and `Not saved: this plan was prepared for a different intervals.icu athlete.` (the card still waits with Save plan and Cancel, because the coach leaves the confirmation open).
- `plan-card-carried` draws a card left waiting at New conversation once at the top of the next conversation. It can be canceled there. After its ten minutes, a relaunch with a later clock shows it Expired at the top.
- `plan-card-not-prepared` shows `The training plan could not be prepared for saving.` as `chat.turn.planSaveNotice` on a turn that called `plan_save` twice in one step, and no card.
- `plan-card-with-review` keeps a waiting workout review and a waiting plan card apart. Each bar acts only on its own card, and saving the plan sends no model request and makes no calendar call.

## How to get to it (user POV)

1. Finish onboarding with the `fixture` key and send `fixture:plan-save`. The reply reads `Your plan is ready. Tap Save plan on the card to keep it.` and the card for `12-Week Gran Fondo Plan` follows it.
2. Tap Save plan or Cancel.
3. Send `fixture:plan-save 10` after a saved plan to see the "replaces" line name it.
4. Tap New conversation with a card still waiting to see it carried to the top.

Directives, typed into `chat.composer`:

| Directive | Card |
| --- | --- |
| `fixture:plan-save` | `12-Week Gran Fondo Plan`, goal `Finish the June gran fondo`, 12 weeks, phases Base building 5 weeks 7 h, Threshold 5 weeks 8.5 h, Taper 2 weeks 4.5 h. |
| `fixture:plan-save <weeks>` | The same plan over `<weeks>` weeks, named `<weeks>-Week Gran Fondo Plan`. Needs more than 2 weeks. |
| `fixture:plan-save-long` | A 16-week plan with a long name and goal and four phases, for wrapping. |
| `fixture:plan-save-sparse` | `Spring Base Plan` with no goal or length and one field per phase. |
| `fixture:plan-save-not-prepared` | Two `plan_save` calls in one step; the turn shows the not-prepared notice and no card. |

Launch arguments, set through `FixtureArguments`:

| Argument | Effect |
| --- | --- |
| `planSaveStage: .saving` (`-EnduragentFixturePlanSave saving`) | The saved-plan write never finishes, so Save plan leaves the card at Saving, also after a relaunch with the same argument. |
| `planSaveStage: .storage` (`-EnduragentFixturePlanSave storage`) | The saved-plan write fails, so Save plan leaves the card at storage unavailable. |
| `planTap: .expired` (`-EnduragentFixturePlanTap expired`) | The first Save plan tap moves the fixture clock 660 seconds before it reaches the coach. |
| `planTap: .replaced` (`-EnduragentFixturePlanTap replaced`) | The first Save plan tap first sends `fixture:plan-save 10` and waits for its card, then sends the older card's tap. |
| `planTap: .twice` (`-EnduragentFixturePlanTap twice`) | Each Save plan tap reaches the coach twice. |
| `clock: "1998-06-15T08:11:00Z"` with `store: .keep` | A relaunch past every card's ten minutes; waiting cards read Expired. |

## Driving it with sim and XCUITest

Each class runs the same flows in one language: `PlanSaveCardEnProof` (English), `PlanSaveCardDeProof` (German), `PlanSaveCardPtPTProof` (Portuguese of Portugal) and `PlanSaveCardZhHantProof` (Traditional Chinese). Every flow has an `AtDefaultSize` and an `AtLargestText` method. Messages are always sent at the default size; a largest-text method relaunches with `store: .keep` and `textSize: .accessibilityXXXL` before it checks. Attachments start with `u7-1-<language>-<standard|largest>-`.

| Command | What it proves |
| --- | --- |
| `sim test <run id> PlanSaveCardDeProof/testWaitingSavedCanceledAndExpiredCardsAtLargestText` | The waiting card opens with the reply and its title on screen; the bar is in the transcript directly under the card (docked above the composer in `AtDefaultSize`); VoiceOver reads the title, name, goal, length, each phase, then Save plan and Cancel; values sit under their labels; both buttons are whole and tappable; the disclaimer is the last row. With `planTap: .twice`, Save plan reads Saved with the already-decided answer. A 10-week card reads `Replaces your saved plan: 12-Week Gran Fondo Plan` before the buttons and keeps the line after Cancel. An 8-week card reopens with its title on screen, then reads Expired after a later-clock relaunch. |
| `sim test <run id> PlanSaveCardDeProof/testSavingShowsNoControlsAtLargestText` | Saving with no control, also after a relaunch. |
| `sim test <run id> PlanSaveCardDeProof/testStorageUnavailableShowsItsNoticeAndNoControlsAtLargestText` | The storage line once, no answer line, no control. |
| `sim test <run id> PlanSaveCardDeProof/testAnExpiredTapIsAnsweredAtLargestText` | Expired with the expired answer. |
| `sim test <run id> PlanSaveCardDeProof/testAReplacedTapIsAnsweredAtLargestText` | The 10-week card waits with its controls; the older card reads Expired with the replaced answer. |
| `sim test <run id> PlanSaveCardDeProof/testATapForAnotherAthleteIsAnsweredAtLargestText` | After `fixture.switchAthlete`, Save plan answers with the athlete-changed sentence, the card keeps Save plan and Cancel, and nothing is saved. |
| `sim test <run id> PlanSaveCardDeProof/testALongNameWrapsAndValuesSitUnderLabelsAtLargestText` | The whole long name on several lines, each phase value under its label, the reading order and whole buttons. |
| `sim test <run id> PlanSaveCardDeProof/testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtLargestText` | The not-prepared notice on the turn and no card. |
| `sim test <run id> PlanSaveCardDeProof/testACarriedCardIsDrawnOnceAtTheTopAtLargestText` | After New conversation the card is drawn once at the top, marked Prepared earlier, opens with its title on screen, has its bar directly under it, and reads Canceled after Cancel. A second carried card reads Expired at the top after a later-clock relaunch. |
| `sim test <run id> PlanSaveCardDeProof/testControlsArmWhenTheTitleIsScrolledIntoViewAtLargestText` | With a long reply after a carried card, the chat opens at the newest message with no Save plan; scrolling the title into view arms the card. |
| `sim test <run id> PlanSaveCardDeProof/testApprovingTheReviewLeavesThePlanWaitingAtLargestText` | A workout review and a plan card both wait, each bar under its own card (review bar then plan bar docked above the composer at the default size). Approve applies the review and the plan keeps Save plan and Cancel. |
| `sim test <run id> PlanSaveCardDeProof/testSavingThePlanLeavesTheReviewWaitingAtLargestText` | In a second launch, Save plan saves the plan, the review still offers Approve, and `fixture.calendarCalls` and `fixture.modelRequestCount` are unchanged. |

Replace `De` with `En`, `PtPT` or `ZhHant`, and `AtLargestText` with `AtDefaultSize`, for the other runs. `sim test <run id> PlanSaveCardDeProof` runs every flow in German.

## Gotchas

- The card arms only once its title has been on screen. A check for Save plan at the largest text size must first scroll to the bar under the card; `ReviewCardReading.reach` does that.
- The fixture clock never moves on its own. Expiry needs `planTap: .expired` or a relaunch with a later `clock`.
- `planSaveStage: .saving` holds the write for the whole process, and recovery on the next launch holds again, so the card stays at Saving until the argument is dropped.
- The docked plan bar shrinks the visible transcript; `TutorialHarness.transcriptBand` ends at the higher of the docked review bar, the docked plan bar and the composer.
- Hours per week follow the phone's number format, so the proofs read the hours label but not its value.
- With `planTap: .replaced` the newer card comes after a new turn at the end of the transcript; wait for it scrolling toward the end, then for the older card scrolling back.
- The accessibility audit redraws the app at other text sizes, and the transcript lays out again afterwards. Capture a screen before its audit, not after.
