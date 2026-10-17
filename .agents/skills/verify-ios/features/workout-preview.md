# Workout review

The coach prepares calendar changes during a turn, and the app commits them as one Workout review when the reply ends. The card appears after the turn that committed it, or at the top of a new conversation marked Prepared earlier, and never during the reply. The athlete approves or cancels the review as one decision. A finished review leaves its outcome lines in the transcript as `chat.note`.

## Sub-features

- `preview-show` displays the workout cards after the turn's reply. The card's buttons come from its control set and each one waits for the card's token, so none is enabled before the card has appeared.
- `preview-control-sets` shows one layout per control set: Cancel and Add to calendar to approve; Try again and Cancel after a change that was not saved; Check again and Cancel for an unconfirmed change; Cancel alone for a blocked review. A finished review has no button.
- `preview-add` runs the review and saves one outcome line per change as `chat.note`, such as `Endurance with tempo, 6/16/1998: change saved.` The lines survive relaunch and are readable in History after New conversation.
- `preview-cancel` closes the review without writing the remaining changes. It stays closed after another message and after relaunch.
- `preview-lost-answer` reads the calendar at once when a write loses its answer. A change found there gives `change seen on the calendar.` with no second write.
- `preview-unconfirmed` keeps an unconfirmed change with Check again and Cancel while the calendar cannot be read. Each time the app comes to the front it reads the change again. A change read as absent goes back to the remaining work with Try again and Cancel.
- `preview-account-changed` blocks a review prepared for another athlete when Add is tapped. The sentence shows as `chat.review.notice` inside the card and only Cancel remains.
- `preview-upgrade` opens reviews saved by build 6833d90f. An open review closes with `This review was prepared before the app was updated. Ask the coach again.` and no control, offline and online. An unknown write opens as an unconfirmed change offline and settles once the calendar can be read. A completed review keeps its notes.
- `preview-storage-unavailable` shows `review.storageUnavailable` on the card when the saved review cannot be read, with no enabled control. The card is readable again the next time the app comes to the front.
- `preview-language` localizes the title, buttons, notices and outcome lines.
- `preview-composer` keeps review rows above the opaque composer when the keyboard opens for a plain message. Send stays hittable.
- `preview-largest-text` keeps the review readable and every control set tappable at the largest accessibility text size in all 17 languages. The accessibility order is the title, the workout, the notice, then the controls.

## How to get to it (user POV)

- Send `Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks` from the conversation.
- Choose Cancel or Add to calendar on the resulting review.
- Change the connected athlete through Settings > intervals.icu, `settings.training`, while a review exists, or through the peer controls in Settings > Debug.
- Launch a build 6833d90f store with `FixtureArguments(store: .openReviewBeforeUpgrade, onboarded: true)`, `.unknownWriteBeforeUpgrade` or `.completedBeforeUpgrade`. Add `calendarReadFault: .failOnce` to open it offline.

## Driving it with sim and XCUITest

Preconditions:

- Follow the [index](./README.md) setup. Approval proofs connect the fixture athlete during onboarding.
- Wait for the button you need to become enabled before tapping. `ReviewCardScreen.assertButtons` checks the exact identifiers, labels and enabled state of one control set.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim test <run id> ReviewUpgradeProof` | The three build 6833d90f stores. The open review shows the ask-again note once with no control, offline and after an online relaunch. The unknown write shows Check again and Cancel offline, Try again and Cancel online after the read finds nothing, then the saved line after Try again. The completed review keeps its note. Attachments start with `u9-2-upgrade-`. |
| `sim test <run id> ReviewLostAnswerProof` | A lost answer is read at once and the line reads `change seen on the calendar.` with no control left, `u9-2-review-lost-answer-seen`. |
| `sim test <run id> ReviewStorageNoticeProof` | The record-read launch hook fails one read after the card is armed. The card shows the storage notice with no enabled control, and a relaunch restores Cancel and Add to calendar without the notice, `u9-2-review-storage-notice`, `u9-2-review-storage-notice-cleared`. |
| `sim test <run id> ReviewCardComposerProof/testKeyboardKeepsReviewRowsAboveTheComposer` | The keyboard opens while a review is visible. Transcript rows and Add stay above the composer, and Send remains hittable, `review-card-composer-keyboard`. |
| `sim test <run id> DifferentAthleteProof` | A replacement for another athlete asks for confirmation while the review waits; Cancel keeps Ada. Switch athlete saves Bo, and Add on the old review shows the athlete-changed sentence with Cancel alone, `different-athlete-confirmation-light`, `different-athlete-saved-light`, `different-athlete-old-review-light`. |
| `sim test <run id> SameAthleteRotationProof` | A replacement for the same athlete keeps the review approvable, `same-athlete-saved-light`, `same-athlete-added-light`. |
| `sim test <run id> ResetKeepsReviewProof` | New conversation shows the waiting review at the top marked Prepared earlier with Cancel and Add to calendar. Records hold `workoutReview` rows and no `reviewOutcome`, `reset-keeps-review`, `reset-keeps-review-records`. |
| `sim test <run id> NoCrossChatMemoProof` | After approval, a later turn retries its server failure and finishes; the earlier prepared-ride reply remains visible without a failure notice, `no-cross-chat-memo-done`, `no-cross-chat-memo`. |

## Largest text size and VoiceOver order

The `ReviewAccessibility` classes prove the review card at the largest accessibility text size in every supported language. Each language has its own class, so one language failing leaves the other results intact. `sim suite` runs three languages: `ReviewAccessibilityDeProof` for German, `ReviewAccessibilityPtPTProof` for Portuguese of Portugal and `ReviewAccessibilityZhHantProof` for Traditional Chinese. The other 14 are release sweeps that `sim suite` runs only when they are named: `ReviewAccessibilityEnSweep`, `ReviewAccessibilityEsSweep`, `ReviewAccessibilityFrSweep`, `ReviewAccessibilityItSweep`, `ReviewAccessibilityNlSweep`, `ReviewAccessibilityDaSweep`, `ReviewAccessibilitySvSweep`, `ReviewAccessibilityNbSweep`, `ReviewAccessibilityFiSweep`, `ReviewAccessibilityPtBRSweep`, `ReviewAccessibilityPlSweep`, `ReviewAccessibilityKoSweep`, `ReviewAccessibilityJaSweep` and `ReviewAccessibilityZhHansSweep`.

| Test method | States it checks, in order |
| --- | --- |
| `testApprovalControls` | A connected athlete. `approval` with Cancel and Add to calendar, `content` scrolled to the workout, `cancelled` after Cancel. Add is reached and not tapped. |
| `testUnconfirmedChangeControls` | The build 6833d90f unknown write, opened offline. `unconfirmed` with Check again and Cancel, `try-again` with Try again and Cancel after Check again finds nothing, `cancelled-unsaved` after Cancel. Try again is reached and not tapped. |
| `testBlockedReviewControls` | A review whose athlete changed through the peer controls before Add. `cancel-only` with Cancel alone, `cancelled-blocked` after Cancel. |

Each flow launches in English at the default text size, finishes onboarding or opens the upgrade store, chooses the language in Settings > Language and reaches its first state. It then relaunches the same store with `FixtureArguments.textSize = .accessibilityXXXL`, which passes `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`. Only the review is driven at the largest size, so typing and Settings stay at the size the harness is proven at. The unconfirmed flow keeps `calendarReadFault: .failOnce` on the relaunch, so the change is still unconfirmed when it is read at the largest size.

For each state the proof reads one accessibility snapshot of the transcript row that holds the review. It fails unless the elements are, in order, the localized title, the workout text, the notice lines, then each control with its catalog title. Each element must start below or to the right of the one before it and stay inside the row. Each control must be enabled and at least 44 points tall, which also fails if the text size did not apply. `performAccessibilityAudit` then checks clipped text, Dynamic Type and hit regions for the elements inside that row. XCUITest cannot drive VoiceOver itself; the snapshot order and the frames are what VoiceOver reads from. Screenshots are named `u9-2-<tag>-<state>`.

The proof does not open Settings > Debug at the largest text size, so it does not read the fixture request count.

Run the 14 release sweeps on two simulators for a release pass. Add the three suite classes to the same command for all 17 languages:

```sh
caffeinate -i env ENDURAGENT_VERIFY_RUNS="$HOME/Library/Logs/enduragent-m4/9.2/simulator-proof" swift run --quiet --package-path tools sim suite --build-folder /tmp/enduragent-dd/9.2-sim --shards 2 ReviewAccessibilityEnSweep ReviewAccessibilityEsSweep ReviewAccessibilityFrSweep ReviewAccessibilityItSweep ReviewAccessibilityNlSweep ReviewAccessibilityDaSweep ReviewAccessibilitySvSweep ReviewAccessibilityNbSweep ReviewAccessibilityFiSweep ReviewAccessibilityPtBRSweep ReviewAccessibilityPlSweep ReviewAccessibilityKoSweep ReviewAccessibilityJaSweep ReviewAccessibilityZhHansSweep
```

To resume, read `summary.md` in the suite folder and run the same command with only the classes that are missing or failed. To repeat one flow of one language, run `sim test <run id> ReviewAccessibilityJaSweep/testApprovalControls`.

## Gotchas

- The fixture presents a review only for a message that contains `endurance ride` and does not start with `/workout` or `/status`. `/workout`, alone or with text after it, waits 8 seconds and replies in text with no workout review.
- The card is committed when the reply ends. Wait for the turn to settle before you look for it.
- `fixture.failNextAppend` fails the next record append. Arm it through `TutorialHarness.fixtureControl` in Settings > Debug after the review is presented and the proposing turn has settled, then tap a button. Reach every Debug row through `TutorialHarness.debugRow`, and use `TutorialHarness.returnToChat` to leave Settings or the language picker.
- `FixtureArguments(calendarSaveFault: .loseAnswerOnce)` stores the change before losing the answer, so the immediate read finds it. `calendarReadFault: .failOnce` affects only the next event list or event fetch; at launch that is the read of an unconfirmed change. The fake calendar starts empty at every launch, so an upgraded unknown write is read as absent once reads work.
- The build 6833d90f stores belong to athlete `i1001` under a fixed connection that the store policy installs. The fixture clock stays on 1998-06-15.
- The fake intervals.icu client keeps calendar writes in memory. The outcome lines and Records are the visible evidence because the app has no calendar screen.
- A waiting review has no timer. It survives New conversation and shows once at the top of the new one.
- The compact phone can truncate a long workout description. Inspect the visible cards and controls, and preserve the screenshot rather than assuming every step fits.
- Interactive captures must restore light appearance afterwards.
- The keyboard proof requires the software keyboard. Also inspect the opaque composer after manually scrolling rows under it.
