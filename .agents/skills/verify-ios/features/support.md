# Support

Support is the Settings section after Session. It holds Feedback, Diagnostics and About, in that order. Each row opens its screen, and Back returns to Settings.

## Sub-features

- `support-section` shows the `Support` header and the rows `settings.feedback`, `settings.diagnostics` and `settings.about`, in that order, below `settings.session`.
- `support-feedback-refusals` refuses a note before anything is sent. An empty note shows `Write a note first.`. A note over 4,000 characters shows `Keep your note to 4,000 characters or fewer. Nothing was sent.`. A note with a NUL character shows the invalid-character sentence. `fixture.feedbackRequests` stays at 0.
- `support-feedback-not-confirmed` keeps a note whose answer was lost. The outcome reads `Not confirmed. The note may have arrived, but no answer came. Your note is kept, and Try again sends the same note.`, the draft stays, and `feedback.tryAgain` replaces Send. Try again sends the same note and shows `Received. Thank you for the note.`. A Not sent outcome keeps the note the same way and names its reason. Editing the kept draft turns Try again back into Send.
- `support-feedback-relaunch` restores a kept not-confirmed note after a relaunch: the draft, the not-confirmed sentence and Try again.
- `support-feedback-received` clears the draft after a received note, so a second Send cannot resend the same note as a new one. A draft edited while the note was sending stays.
- `support-feedback-field` is four lines tall and scrolls inside itself, so a long note keeps Send and the outcome line above the keyboard.
- `support-diagnostics-share` makes the diagnostics file and opens the iOS share sheet. Close shows `Canceled. The file was not shared.`, Copy or another app shows `Shared. iOS handed the file to the app you chose.`, Save to Files shows `Saved to Files.`, and a share error shows `The file could not be shared.`. The make button returns after each outcome, and the share folder is empty again.
- `support-diagnostics-not-saving` shows `This phone has not saved the problem log since <date time>. …` above the explanation when the journal has stopped saving. The time is the coach clock's date and clock in its zone.
- `support-about` shows the app name `Enduragent`, `Version 0.1.0 (3)` and the Privacy policy link, which opens Safari.

## How to get to it (user POV)

- Finish setup or choose Skip, then accept provider consent.
- Tap the gear icon labeled Settings, scroll below Session, and tap Feedback, Diagnostics or About.
- On Feedback, type in `feedback.field` and tap `feedback.send`, or `feedback.tryAgain` when a note is kept.
- On Diagnostics, tap `diagnostics.make`, then pick an action in the share sheet.
- On About, tap `about.privacyPolicy`.

## Driving it with sim and XCUITest

Follow the [index](./README.md) setup. Use a 390 pt wide iPhone. Every launch uses the fake feedback server; no proof reaches the live feedback service.

| Command | Observable result and attachment |
| --- | --- |
| `sim test <run id> SupportSectionProof` | The Support header follows Session, the three rows read Feedback, Diagnostics and About in order, each opens its screen, and Back returns to Settings. `support-section-light`. |
| `sim test <run id> FeedbackScreenProof/testRefusals` | Empty Send shows the empty sentence; a 4,001-character note shows the too-long sentence with 4,000, above the keyboard; Debug reads `0 feedback requests`. `feedback-too-long-light`. |
| `sim test <run id> FeedbackScreenProof/testTraceLostLostThenTryAgain` | Launch with `-EnduragentFixtureFeedback lost,lost`. Send shows the not-confirmed sentence and keeps the draft; Try again shows Received; Debug reads `3 feedback requests` and `1 feedback notes stored`. `feedback-not-confirmed-light`. |
| `sim test <run id> FeedbackScreenProof/testRelaunchKeepsNotConfirmedNoteAndTryAgainSendsIt` | After a not-confirmed note, a relaunch without the script shows the kept text, the sentence and Try again; Try again shows Received and Debug reads `1 feedback notes stored`. `feedback-kept-after-relaunch-light`. |
| `sim test <run id> DiagnosticsScreenProof/testCancelShowsCanceled` | Close on the share sheet shows the canceled sentence and the make button again. `diagnostics-canceled-light`. |
| `sim test <run id> DiagnosticsScreenProof/testCopyShowsShared` | Copy shows the shared sentence. `diagnostics-shared-light`. |
| `sim test <run id> DiagnosticsScreenProof/testSaveToFilesOnMyIPhoneShowsSaved` | Save to Files, On My iPhone, Save shows `Saved to Files.`. On a rerun, iOS asks to replace the file from the earlier run, and the proof taps Replace. `diagnostics-saved-light`. |
| `sim test <run id> DiagnosticsScreenProof/testNotSavingLine` | Launch with `-EnduragentFixtureJournal notSaving`. `diagnostics.notSaving` reads the not-saving sentence with the fixture clock's 1998-06-15 time in Europe/Ljubljana. `diagnostics-not-saving-light`. |
| `sim test <run id> AboutScreenProof` | `about.value.name` reads Enduragent, `about.version` reads `Version 0.1.0 (3)`, and the Privacy policy link brings Safari to the foreground. `about-light`. |

The hosted `FeedbackLineTests` suite maps every refusal and feedback status to its sentence and button, including Try again for a draft that trims to the kept note, and maps journal health to the not-saving line. The hosted `SupportShareTests.eachShareCompletionShowsItsLine` feeds literal share activity strings into `SupportModel.shareFinished` and checks each line and the empty share folder. The hosted `FeedbackDraftTests.receivedClearsOnlyTheDraftThatWasSent` holds a send at the fake server, edits the draft, and checks that Received keeps the edit.

Fixture handles: `-EnduragentFixtureFeedback` takes comma-separated answers (`lost`, `offline`, `timeout` or an HTTP status) that the fake server gives in order before it stores notes. `-EnduragentFixtureJournal notSaving` starts with a journal that cannot write. Debug shows `fixture.feedbackRequests` and `fixture.feedbackStored`.

## Gotchas

- The share sheet and the Files picker are system UI. Their buttons are found by English label (`Close`, `Copy`, `Save to Files`, `On My iPhone`, `Save`, `Replace`), so run the Diagnostics proofs with an English simulator.
- The share sheet cannot be swiped away; the activity view's completion is the only source of an outcome.
- `testRefusals` types 4,001 characters, which takes a while.
- `relaunchKeepingStore(clearingFeedbackScript: true)` drops the feedback script, so the relaunched fake server stores the note.
