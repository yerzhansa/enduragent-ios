# Your data

Your data is the Settings section after Support. Its one row, Delete everything, opens a screen that deletes the athlete's data from this iPhone, iCloud, iCloud Keychain and the Credits service. The coach's `DataErasure` run asks the Credits service first, then deletes the synced records, the device-local records, the files, the Keychain items and the app's settings.

## Sub-features

- `your-data-section` shows the `Your data` header after Support and the row `settings.yourData`, labeled `Delete everything`.
- `your-data-screen` shows `yourData.keeps`, which says intervals.icu and an own OpenRouter key stay, and the destructive `yourData.delete`. Delete everything opens an alert titled `Delete everything?` with the confirm body, `Delete everything` and `Cancel`.
- `your-data-busy` shows `Wait for the coach to finish, then try again.` under the button while a turn, a memory save or a review write runs, or while a message waits to join the next one. Nothing is deleted.
- `your-data-done` replaces the app with the deleting screen, `yourData.progress`, `Deleting…` and `yourData.progressTime`, `This can take up to a minute.`, then `Everything is deleted from this iPhone, your iCloud and the Credits service.` and `yourData.continue`. Continue reopens the app on the health notice as on a fresh install, with a new device id. After onboarding the chat is empty.
- `your-data-not-started` shows `Nothing was deleted. Connect to the internet and try again.` when the Credits service gives no answer. `yourData.tryAgain` asks again. `yourData.cancel` returns to the chat with the conversation intact.
- `your-data-try-later` shows `Nothing was deleted from this iPhone or your iCloud. The Credits service is busy right now. Try again later.` when the Credits service answers 429 or 503, with the same `yourData.tryAgain` and `yourData.cancel`.
- `your-data-credits-unconfirmed` shows `Nothing was deleted. The Credits service couldn't confirm that this iPhone owns your Credits record, so the record stays there. You can still delete everything on this iPhone and in your iCloud.` when the Credits service answers 401, with `yourData.deleteHere`, `Delete from iPhone and iCloud`, and `yourData.cancel`. Delete from iPhone and iCloud runs the local steps without asking the Credits service again and ends with `Everything is deleted from this iPhone and your iCloud. Your Credits record stays on the Credits service. No one holds its key, so no one can use it.`, or the iCloud-later form of that sentence.
- `your-data-icloud-later` shows `Deleted from this iPhone and the Credits service. Your iCloud copy is deleted the next time you open Enduragent while this iPhone is online and signed in to iCloud. If you delete the app before then, delete its data in iOS Settings under iCloud storage.` when iCloud does not confirm the deletes within 60 seconds, when there is no iCloud account, or when the synced store held no rows, because an empty store proves nothing about iCloud. The next launch deletes synced rows written before the deletion began, by any device, and clears the marker after an export. Rows written after it began stay.
- `your-data-not-finished` shows `Not everything was deleted from this iPhone. Try again.` when a step on this iPhone fails after the Credits service confirmed. Try again resumes without asking the Credits service again.
- `your-data-resume` opens the deleting screen at launch when the app was killed mid-run, finishes the run, and shows the outcome. A run killed after it deleted the synced rows waits for a new iCloud export, and without one it shows the iCloud-later sentence, never done.
- `your-data-largest-text` keeps the row, the screen text, the button, the deleting screen and every outcome line and button whole at the largest accessibility text size.

## How to get to it (user POV)

- Finish setup or choose Skip, then accept provider consent.
- Tap the gear icon labeled Settings, scroll below Support, and tap Delete everything.
- Tap `yourData.delete`, then Delete everything in the alert.

## Driving it with sim and XCUITest

Follow the [index](./README.md) setup. `-EnduragentFixtureErasure` sets the fake Credits erase answer and the fake iCloud export: `erased` (the default) confirms both, `unreachable` makes the Credits service fail, `icloud-later` reports no iCloud account, `export-held` never confirms the export, so the run stays on Deleting until the app is killed, `refused` makes the Credits service answer 401, `refused-icloud-later` answers 401 and reports no iCloud account, and `rate-limited` makes it answer 429. `unreachable` gives no answer. After Continue, the fixture reopens with `-EnduragentFixtureStore keep`, so the reopened app sees the deleted state. Do not pass `-enduragent.onboardingCompleted YES` to see the notice after Continue: that argument cannot be deleted.

| Command | Observable result and attachment |
| --- | --- |
| `sim test <run id> YourDataProof/testDeleteEverythingOpensOnboardingAsAFreshInstall` | After one reply, the screen reads the keeps sentence and Delete everything; the alert reads its title, body and Cancel; the done sentence and Continue follow; Continue shows the health notice; after Skip and consent the chat reads `turns 0 settled 0` and no earlier reply. `your-data-screen-light`, `your-data-confirm-light`, `your-data-done-light`, `your-data-onboarding-after-light`. |
| `sim test <run id> YourDataProof/testUnreachableCreditsServiceDeletesNothing` | Launch with `-EnduragentFixtureErasure unreachable`. The not-started sentence shows with Try again and Cancel; Try again shows it again; Cancel returns to the chat with `turns 1 settled 1` and the week reply. `your-data-not-started-light`, `your-data-not-started-chat-light`. |
| `sim test <run id> YourDataProof/testICloudLaterFinishesOnThisPhone` | Launch with `-EnduragentFixtureErasure icloud-later`. The iCloud-later sentence and Continue show; Continue shows the health notice. `your-data-icloud-later-light`. |
| `sim test <run id> YourDataProof/testKilledRunResumesOnTheNextLaunch` | Launch with `-EnduragentFixtureErasure export-held`. Deleting and the one-minute line show; the app is killed and reopened with the store kept and `icloud-later`; it opens on the deleting screen, not the chat, and shows the iCloud-later sentence; Continue shows the health notice. `your-data-deleting-light`, `your-data-resumed-icloud-later-light`. |
| `sim test <run id> YourDataProof/testAnUnconfirmedCreditsRecordOffersToDeleteThisPhoneAndICloud` | Launch with `refused`. The credits-unconfirmed sentence shows with Delete from iPhone and iCloud and Cancel, and no Try again; Delete from iPhone and iCloud shows the credits-kept done sentence; Continue and onboarding show an empty chat. `your-data-credits-unconfirmed-light`, `your-data-credits-kept-done-light`. |
| `sim test <run id> YourDataProof/testABusyCreditsServiceSaysToTryAgainLater` | Launch with `rate-limited`. The try-later sentence shows with Try again and Cancel; Cancel returns to the chat with `turns 1 settled 1`. `your-data-try-later-light`. |
| `sim test <run id> YourDataProof/testLargestTextKeepsEveryLineAndControlWhole` | At `accessibilityXXXL` with `unreachable`, the row, the keeps sentence, the button, the alert, the not-started sentence, Try again and Cancel each lie whole inside the window. `largest-en-your-data-row-light`, `largest-en-your-data-screen-light`, `largest-en-your-data-confirm-light`, `largest-en-your-data-not-started-light`. |
| `sim test <run id> YourDataProof/testLargestTextKeepsTheDeletingAndICloudLaterScreensWhole` | After one reply, reopened at `accessibilityXXXL` with `export-held`: Deleting and the one-minute line lie whole; reopened with `icloud-later`, the iCloud-later sentence and Continue lie whole. `largest-en-your-data-deleting-light`, `largest-en-your-data-icloud-later-light`. |
| `sim test <run id> YourDataProof/testLargestTextKeepsTheDoneScreenWhole` | The same with `erased`: the done sentence and Continue. `largest-en-your-data-done-light`. |
| `sim test <run id> YourDataProof/testLargestTextKeepsTheCreditsRecordOfferAndItsOutcomeWhole` | The same with `refused-icloud-later`: the offer sentence, Delete from iPhone and iCloud and Cancel; then the credits-kept iCloud-later sentence and Continue. `largest-en-your-data-credits-unconfirmed-light`, `largest-en-your-data-credits-kept-icloud-later-light`. |
| `sim test <run id> YourDataProof/testLargestTextKeepsTheTryLaterScreenWhole` | The same with `rate-limited`: the try-later sentence, Try again and Cancel. `largest-en-your-data-try-later-light`. |

The package suites `CreditsErasureTests`, `StoreErasureTests` and `DataErasureTests` prove the Credits call, each store's delete, the busy guard and a run that stops after each step and resumes. The hosted `KeychainErasureTests` proves on the simulator that one delete removes synchronized and this-device-only Keychain items of the app's service and leaves another service's items. `make test-app` and CI skip it. Run it after every change to `SecretStore.swift` or `KeychainQuery`, on your own simulator, from the repository root:

```sh
make test-keychain SIMULATOR=<udid of your enduragent-verify simulator> DERIVED_DATA=/tmp/enduragent-dd/<task>-keychain
```

It passes when the log shows `✔ Test deleteEverythingRemovesSynchronizedAndThisDeviceOnlyItemsOfTheService() passed`. A line saying the test was skipped means `ENDURAGENT_KEYCHAIN_TESTS` did not reach the test runner.

## Gotchas

- Never run Delete everything outside fixture mode on a device that holds real keys. It deletes the app's iCloud Keychain items on every device signed in to the same Apple Account.
- The busy state has no XCUITest proof. `DataErasureTests.aRunningTurnOrAnOpenMessageWindowRefusesToBegin` covers it.
- `your-data-not-finished` has no XCUITest proof. `DataErasureTests.aRunStoppedAtAStepResumesAfterRelaunchWithoutAskingCreditsAgain` covers each step.
