# Support

Support is the Settings section after Session. It holds Feedback, Diagnostics and About, in that order. Each row opens its screen, and Back returns to Settings.

## Sub-features

- `support-section` shows the `Support` header and the rows `settings.feedback`, `settings.diagnostics` and `settings.about`, in that order, below `settings.session`.
- `support-feedback-refusals` refuses a note before anything is sent. An empty note shows `Write a note first.`. A note over 4,000 characters shows `Keep your note to 4,000 characters or fewer. Nothing was sent.`. A note with a NUL character shows the invalid-character sentence. `fixture.feedbackRequests` stays at 0.
- `support-feedback-not-confirmed` keeps a note whose answer was lost. The outcome reads `Not confirmed. The note may have arrived, but no answer came. Your note is kept, and Try again sends the same note.`, the draft stays, and `feedback.tryAgain` replaces Send. Try again sends the same note and shows `Received. Thank you for the note.`. A Not sent outcome keeps the note the same way and names its reason. Editing the kept draft turns Try again back into Send.
- `support-feedback-relaunch` restores a kept not-confirmed note after a relaunch: the draft, the not-confirmed sentence and Try again.
- `support-feedback-received` clears the draft after a received note, so a second Send cannot resend the same note as a new one. A draft edited while the note was sending stays.
- `support-feedback-field` is four lines tall when empty, grows with the text up to eight lines, and then scrolls inside itself. The screen is a scroll view of two grouped boxes, not a `Form`: a `Form` row grows with all the text of a scrolling field, so a long note pushed Send off the screen. With the keyboard up, the screen scrolls so Send or Try again can be brought above the keyboard. Send and Try again close the keyboard, so the outcome line and the button never sit under it.
- `support-diagnostics-share` makes the diagnostics file and opens the iOS share sheet. Close shows `Canceled. The file was not shared.`, Copy or another app shows `Shared. iOS handed the file to the app you chose.`, Save to Files shows `Saved to Files.`, and a share error shows `The file could not be shared.`. The make button returns after each outcome, and the share folder is empty again.
- `support-diagnostics-not-saving` shows `This phone has not saved the problem log since <date time>. …` above the explanation when the journal has stopped saving. The time is the coach clock's date and clock in its zone.
- `support-about` shows the app name `Enduragent`, the `Version` label with the value `0.1.0 (3)`, and the Privacy policy link, which opens Safari. At the default size the value sits beside its label; at accessibility sizes it sits under it.
- `support-largest-text` fixes the layout at the largest accessibility text size. Each Support row wraps its whole label and the whole row is the tap target. Feedback stacks the prompt, the field, the outcome line and one full-width Send or Try again. Diagnostics stacks the not-saving line, the explanation, the full-width Make diagnostics file and the outcome line. About puts the version value under its label. Session settings puts each label on its own line above a full-width field, with the unit beside the field only when both fit, then the rejection sentence and the help text, and full-width Save and Cancel. VoiceOver reads each screen top to bottom in that order.
- `support-feedback-command` opens Feedback from the chat. `/feedback the lap table is cut off` opens it with `the lap table is cut off` as the draft and Send, and clears the composer. Nothing is stored in the conversation, no model request is made, and nothing reaches the feedback server until Send is tapped on Feedback. One Back returns to the conversation. `/feedback` with no text opens Feedback with the draft it had. With a kept note, `/feedback other text` shows `other text` and Send while the kept note stays: editing the field back to the kept text shows Try again. Send with `other text` keeps a new note in place of the old one, and Try again then resends that new note.
- `support-version-command` opens About from the chat with `/version`, with no message stored and no model request.
- `support-language` reads every Support string in the chosen language and follows a fixed language and Automatic like the rest of the app. The 17 `testSupport` methods of the language matrix walk the section, each Feedback outcome, Diagnostics through Canceled, and About in every language; see the [language page](./language.md).

## How to get to it (user POV)

- Finish setup or choose Skip, then accept provider consent.
- Tap the gear icon labeled Settings, scroll below Session, and tap Feedback, Diagnostics or About.
- On Feedback, type in `feedback.field` and tap `feedback.send`, or `feedback.tryAgain` when a note is kept.
- On Diagnostics, tap `diagnostics.make`, then pick an action in the share sheet.
- On About, tap `about.privacyPolicy`.
- From the chat, type `/feedback` with or without text, or `/version`, and tap Send.

## Driving it with sim and XCUITest

Follow the [index](./README.md) setup. Use a 390 pt wide iPhone. Every launch uses the fake feedback server; no proof reaches the live feedback service.

| Command | Observable result and attachment |
| --- | --- |
| `sim test <run id> SupportSectionProof` | The Support header follows Session, the three rows read Feedback, Diagnostics and About in order, each opens its screen, and Back returns to Settings. `support-section-light`. |
| `sim test <run id> FeedbackScreenProof/testRefusals` | Empty Send shows the empty sentence; after a 4,001-character note, Send scrolls wholly above the keyboard, and the too-long sentence with 4,000 is wholly above the keyboard or the keyboard is gone; Debug reads `0 feedback requests`. `feedback-too-long-light`. |
| `sim test <run id> FeedbackScreenProof/testTraceLostLostThenTryAgain` | Launch with `-EnduragentFixtureFeedback lost,lost`. Send shows the not-confirmed sentence and keeps the draft; Try again and then Received are wholly above the keyboard or the keyboard is gone; Debug reads `3 feedback requests` and `1 feedback notes stored`. `feedback-not-confirmed-light`. |
| `sim test <run id> FeedbackScreenProof/testRelaunchKeepsNotConfirmedNoteAndTryAgainSendsIt` | After a not-confirmed note, a relaunch without the script shows the kept text, the sentence and Try again; Try again shows Received and Debug reads `1 feedback notes stored`. `feedback-kept-after-relaunch-light`. |
| `sim test <run id> DiagnosticsScreenProof/testCancelShowsCanceled` | Close on the share sheet shows the canceled sentence and the make button again. `diagnostics-canceled-light`. |
| `sim test <run id> DiagnosticsScreenProof/testCopyShowsShared` | Copy shows the shared sentence. `diagnostics-shared-light`. |
| `sim test <run id> DiagnosticsScreenProof/testSaveToFilesOnMyIPhoneShowsSaved` | Save to Files, On My iPhone, Save shows `Saved to Files.`. On a rerun, iOS asks to replace the file from the earlier run. A tap while the alert animates in is ignored, so the proof taps Replace whenever it is hittable until `Saved to Files.` appears. `diagnostics-saved-light`. |
| `sim test <run id> DiagnosticsScreenProof/testNotSavingLine` | Launch with `-EnduragentFixtureJournal notSaving`. `diagnostics.notSaving` reads the not-saving sentence with the fixture clock's 1998-06-15 time in Europe/Ljubljana. `diagnostics-not-saving-light`. |
| `sim test <run id> AboutScreenProof` | `about.value.name` reads Enduragent, `about.version` reads `Version`, `about.value.version` reads `0.1.0 (3)`, and the Privacy policy link brings Safari to the foreground. `about-light`. |
| `sim test <run id> SupportCommandProof/testFeedbackCommandOpensDraft` | `/feedback the lap table is cut off` opens Feedback with that draft and Send; one Back shows the chat with an empty composer and `turns 0 settled 0`; Debug reads `0 feedback requests`; Send on Feedback shows Received and Debug reads `1 feedback requests` and `1 feedback notes stored`. `feedback-command-draft-light`. |
| `sim test <run id> SupportCommandProof/testBareFeedbackKeepsDraft` | A draft typed on Feedback stays after Back to the chat; `/feedback` opens Feedback with that draft, and one Back shows an empty composer. `feedback-command-bare-light`. |
| `sim test <run id> SupportCommandProof/testVersionOpensAbout` | `/version` opens About with Enduragent and the version line; one Back shows an empty composer; `fixture.modelRequestCount` reads the same before and after. `version-command-about-light`. |
| `sim test <run id> SupportCommandProof/testFeedbackCommandWithAKeptNote` | Launch with `-EnduragentFixtureFeedback lost,lost,lost,lost`. A note ends not confirmed; `/feedback other text` shows `other text` and Send; the kept text shows Try again; Send with `other text` ends not confirmed and keeps it, so the first note's text shows Send and `other text` shows Try again, which shows Received; Debug reads `5 feedback requests` and `2 feedback notes stored`. `feedback-command-kept-note-light`. |
| `sim test <run id> SupportLargestTextProof/testSupportRowsWrap` | At `accessibilityXXXL` in English, each Support row reads its whole title, lies inside the window, spans the row, and opens its screen from its trailing edge. `largest-en-row-settings.feedback-light` and the other two rows. |
| `sim test <run id> SupportLargestTextProof/testFeedbackStacks` | Empty Send shows the empty sentence under the field and Send under it, as wide as the field. A typed note grows the field; with the keyboard up, Send scrolls wholly above the keyboard and shows Received. `largest-en-feedback-stacked-light`, `largest-en-feedback-send-above-keyboard-light`. |
| `sim test <run id> SupportLargestTextProof/testDiagnosticsOrder` | Launch with `-EnduragentFixtureJournal notSaving`. After Make and Close, the not-saving line, the explanation, the full-width Make diagnostics file and the canceled line follow each other and each lies inside the window. `largest-en-diagnostics-order-light`. |
| `sim test <run id> SupportLargestTextProof/testAboutValueUnderLabel` | `0.1.0 (3)` sits under `Version`, and the Privacy policy link brings Safari to the foreground. `largest-en-about-value-under-label-light`. |
| `sim test <run id> SupportLargestTextProof/testReadingOrder` | VoiceOver order on Feedback, Diagnostics and About runs top to bottom in the layout order above. `largest-en-about-reading-order-light`. |
| `sim test <run id> SupportLargestTextProof/testDefaultSizeKeepsInlineRows` | At the default size, About's value shares its label's line, each Session field shares its label's line, and Feedback's Send is under the field. `about-default-size-light`, `session-default-size-light`, `feedback-default-size-light`. |
| `sim test <run id> SupportLargestTextDeProof` | The five largest-text methods above in German, the longest language on these screens. Attachments start with `largest-de-`. |
| `sim test <run id> SupportLanguageProof` | French chosen in Settings: the Support header and rows, Feedback's title, prompt and Send, Diagnostics' title, explanation and Make diagnostics file, and About's title, Version label and Privacy policy link read the French catalog values, and the sweep finds no English. After Automatic on the English phone, the same strings read in English. Attachments `u9-5b-fr-support-section`, `u9-5b-fr-feedback`, `u9-5b-fr-diagnostics`, `u9-5b-fr-about`, then the same names with `en`. |
| `sim test <run id> SessionSettingsLargestTextProof` | At `accessibilityXXXL` in English, each Session label sits above its full-width field, with the unit beside it or under it; a rejected `0` shows its sentence under the field; Save and Cancel each read whole, span the row and can be tapped; VoiceOver reads label, field, unit and help for each field, then Save and Cancel. Attachments start with `largest-en-session-`. |
| `sim test <run id> SessionSettingsLargestTextDeProof` | The same two methods in German. Attachments start with `largest-de-session-`. |

The hosted `FeedbackLineTests` suite maps every refusal and feedback status to its sentence and button, including Try again for a draft that trims to the kept note, and maps journal health to the not-saving line. The hosted `SupportShareTests.eachShareCompletionShowsItsLine` feeds literal share activity strings into `SupportModel.shareFinished` and checks each line and the empty share folder. The hosted `FeedbackDraftTests.receivedClearsOnlyTheDraftThatWasSent` holds a send at the fake server, edits the draft, and checks that Received keeps the edit.

Fixture handles: `-EnduragentFixtureFeedback` takes comma-separated answers (`lost`, `offline`, `timeout` or an HTTP status) that the fake server gives in order before it stores notes. `-EnduragentFixtureJournal notSaving` starts with a journal that cannot write. Debug shows `fixture.feedbackRequests` and `fixture.feedbackStored`.

## Gotchas

- The share sheet and the Files picker are system UI. Their buttons are found by English label (`Close`, `Copy`, `Save to Files`, `On My iPhone`, `Save`, `Replace`), so run the Diagnostics proofs with an English simulator.
- The share sheet cannot be swiped away; the activity view's completion is the only source of an outcome.
- `testRefusals` types 4,001 characters, which takes a while.
- `relaunchKeepingStore(clearingFeedbackScript: true)` drops the feedback script, so the relaunched fake server stores the note.
- `SupportCommandProof`, `FeedbackScreenProof` and the matrix's `testSupport` methods read `fixture.feedbackRequests`; run them in separate shards.
- `SupportLargestTextProof` and `DiagnosticsScreenProof` both start the journal with `notSaving`; run them in separate shards.
- The German largest-text proofs choose German in the language picker before they relaunch at the largest size, so the share sheet stays English. Keep them out of the shard that runs `SettingsLargestTextSweepProof`.
