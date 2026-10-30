# Your data

Your data is the Settings section after Support. Its one row, Delete everything, opens a screen that deletes the athlete's data from this iPhone, iCloud, iCloud Keychain and the Credits service. The coach's `DataErasure` run asks the Credits service first, then deletes the synced records, the device-local records, the files, the Keychain items and the app's settings.

## Sub-features

- `your-data-section` shows the `Your data` header after Support and the row `settings.yourData`, labeled `Delete everything`.
- `your-data-screen` shows `yourData.keeps`, which says intervals.icu and an own OpenRouter key stay, and the destructive `yourData.delete`. Delete everything opens an alert titled `Delete everything?` with the confirm body, `Delete everything` and `Cancel`.
- `your-data-busy` shows `Wait for the coach to finish, then try again.` under the button while a turn, a memory save or a review write runs, or while a message waits to join the next one. Nothing is deleted.
- `your-data-done` replaces the app with the deleting screen, `yourData.progress` and `Deleting…`, then `Everything is deleted from this iPhone, your iCloud and the Credits service.` and `yourData.continue`. Continue reopens the app on the health notice as on a fresh install, with a new device id. After onboarding the chat is empty.
- `your-data-not-started` shows `Nothing was deleted. Connect to the internet and try again.` when the Credits service does not confirm. `yourData.tryAgain` asks again. `yourData.cancel` returns to the chat with the conversation intact.
- `your-data-icloud-later` shows `Deleted from this iPhone and the Credits service. Your iCloud copy is deleted the next time this iPhone connects to iCloud.` when iCloud does not confirm the deletes within 60 seconds, or there is no iCloud account. The next launch deletes synced rows written by the old device id.
- `your-data-not-finished` shows `Not everything was deleted from this iPhone. Try again.` when a step on this iPhone fails after the Credits service confirmed. Try again resumes without asking the Credits service again.
- `your-data-resume` opens the deleting screen at launch when the app was killed mid-run, finishes the run, and shows the outcome.
- `your-data-largest-text` keeps the row, the screen text, the button and every outcome line and button whole at the largest accessibility text size.

## How to get to it (user POV)

- Finish setup or choose Skip, then accept provider consent.
- Tap the gear icon labeled Settings, scroll below Support, and tap Delete everything.
- Tap `yourData.delete`, then Delete everything in the alert.

## Driving it with sim and XCUITest

Follow the [index](./README.md) setup. `-EnduragentFixtureErasure` sets the fake Credits erase answer and the fake iCloud export: `erased` (the default) confirms both, `unreachable` makes the Credits service fail, `icloud-later` reports no iCloud account, and `export-held` never confirms the export, so the run stays on Deleting until the app is killed. After Continue, the fixture reopens with `-EnduragentFixtureStore keep`, so the reopened app sees the deleted state. Do not pass `-enduragent.onboardingCompleted YES` to see the notice after Continue: that argument cannot be deleted.

| Command | Observable result and attachment |
| --- | --- |
| `sim test <run id> YourDataProof/testDeleteEverythingOpensOnboardingAsAFreshInstall` | After one reply, the screen reads the keeps sentence and Delete everything; the alert reads its title, body and Cancel; the done sentence and Continue follow; Continue shows the health notice; after Skip and consent the chat reads `turns 0 settled 0` and no earlier reply. `your-data-screen-light`, `your-data-confirm-light`, `your-data-done-light`, `your-data-onboarding-after-light`. |
| `sim test <run id> YourDataProof/testUnreachableCreditsServiceDeletesNothing` | Launch with `-EnduragentFixtureErasure unreachable`. The not-started sentence shows with Try again and Cancel; Try again shows it again; Cancel returns to the chat with `turns 1 settled 1` and the week reply. `your-data-not-started-light`, `your-data-not-started-chat-light`. |
| `sim test <run id> YourDataProof/testICloudLaterFinishesOnThisPhone` | Launch with `-EnduragentFixtureErasure icloud-later`. The iCloud-later sentence and Continue show; Continue shows the health notice. `your-data-icloud-later-light`. |
| `sim test <run id> YourDataProof/testKilledRunResumesOnTheNextLaunch` | Launch with `-EnduragentFixtureErasure export-held`. Deleting shows; the app is killed and reopened with the store kept; it opens on the deleting screen, not the chat, and shows the done sentence; Continue shows the health notice. `your-data-deleting-light`, `your-data-resumed-done-light`. |
| `sim test <run id> YourDataProof/testLargestTextKeepsEveryLineAndControlWhole` | At `accessibilityXXXL` with `unreachable`, the row, the keeps sentence, the button, the alert, the not-started sentence, Try again and Cancel each lie whole inside the window. `largest-en-your-data-row-light`, `largest-en-your-data-screen-light`, `largest-en-your-data-confirm-light`, `largest-en-your-data-not-started-light`. |

The package suites `CreditsErasureTests`, `StoreErasureTests` and `DataErasureTests` prove the Credits call, each store's delete, the busy guard and a run that stops after each step and resumes. The hosted `KeychainErasureTests` proves on the simulator that one delete removes synchronized and this-device-only Keychain items of the app's service and leaves another service's items.

## Gotchas

- Never run Delete everything outside fixture mode on a device that holds real keys. It deletes the app's iCloud Keychain items on every device signed in to the same Apple Account.
- The busy state has no XCUITest proof. `DataErasureTests.aRunningTurnOrAnOpenMessageWindowRefusesToBegin` covers it.
- `your-data-not-finished` has no XCUITest proof. `DataErasureTests.aRunStoppedAtAStepResumesAfterRelaunchWithoutAskingCreditsAgain` covers each step.
