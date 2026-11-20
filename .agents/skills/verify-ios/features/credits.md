# Credits

The athlete's Credits screen shows available Credits, the three Credits packs with their App Store prices and a Buy button each, the outcome of the last purchase, and a notice when Credits run out or cannot load. Credits are the only way to pay for the coach. Each iPhone gets starter Credits once, and the athlete buys more on this screen only. Settings opens Credits under Model access. The out-of-Credits and no-Credits notices under a turn offer only Buy Credits, which opens this screen.

## Sub-features

- `credits-balance` shows the fixture's `200 credits` in `credits.balance`.
- `credits-unavailable` shows `Credits are unavailable right now. Try again later.` in `credits.notice` when loading fails. At zero Credits the same element shows the out-of-Credits sentence.
- `credits-packs` lists `401 credits · $4.99`, `802 credits · $9.99` and `1,606 credits · $19.99` in `credits.pack.<product id>`, each with `credits.buy.<product id>`. While a purchase runs, its row shows a spinner and the other Buy buttons are disabled.
- `credits-purchase` shows the purchase outcome in `credits.purchaseNotice`: `Added 401 credits`; the pending, purchase-failed, not-added-yet and can't-be-added sentences; nothing after the athlete closes Apple's payment sheet. The can't-be-added sentence offers `credits.purchaseAction`, Ask Apple for a refund, which opens Apple's refund sheet.
- `credits-not-for-sale` shows `Credits can't be bought right now. Try again later.` in `credits.notForSale` and no Buy button when the catalog has purchases off or the App Store returns no prices.
- `credits-recovery` offers only `chat.turn.buyCredits` under an out-of-Credits turn, `You're out of Credits. You can buy Credits.`, and under a no-Credits turn, `This iPhone has no Credits. You can buy Credits.` It opens Credits above the conversation without replacing it. A rejected-Credits turn, and a turn whose Credits record the app cannot read, show `Your Credits couldn't be used. You can tell us in Feedback, in Settings.` with no button.
- `credits-language` renders the title, amount, pack rows, Buy, purchase sentences and failure notice through the current language preference.

## How to get to it (user POV)

- Tap Settings, then Credits under Model access from the conversation.
- Tap Buy Credits under an out-of-Credits or no-Credits turn.
- Receive starter Credits during [onboarding](./onboarding.md).
- Debug, Credits is a separate developer entry for grant and identity diagnostics. It has no purchase controls and does not replace the athlete's Credits screen.

## Driving it with sim and XCUITest

Preconditions:

- Follow the [index](./README.md) setup. Interactive steps begin after onboarding.

`-EnduragentFixturePurchase` sets what the fake App Store and the fake Credits service answer to a Buy tap: `added` (the default), `pending`, `cancel`, `fail`, `not-added-yet` (the Credits service is unavailable, so the purchase stays unfinished), `refused` (the Credits service refuses for good, so the purchase is finished and Ask Apple for a refund appears) or `not-for-sale` (the catalog has purchases off).

| Action and command | Observable result and attachment |
| --- | --- |
| `sim test <run id> CreditsProof` | `chat.settings`, then `settings.credits` under Model access, opens 200 credits and the three packs with enabled Buy buttons, `06-credits`. |
| `sim test <run id> CreditsPurchaseProof` | At zero Credits, `fixture:fail 402` offers Buy Credits, which opens Credits; Buy adds 401 credits and the coach replies, `purchase-out-of-credits`, `purchase-credits-screen`, `purchase-added`, `purchase-reply-on-credits`. Each other outcome shows its sentence, `purchase-pending`, `purchase-cancel`, `purchase-fail`, `purchase-not-added-yet`, `purchase-refused`, `purchase-refund-requested`, `purchase-not-for-sale`. |
| `sim test <run id> NoticeCopyProof` | `fixture:fail 402` offers only Buy Credits and no Try again; Buy Credits opens Credits at 0 credits, `notice-copy-credits-exhausted`, `notice-copy-buy-credits-opens-credits`. `fixture:fail 401` shows the rejected-Credits sentence with no button, `notice-copy-access-rejected`. `BillingIdentityProof` and the hosted `FixtureLaunchTests.outOfCreditsNoticeReturnsToConversationAfterOneBack` prove Buy Credits opens Credits and one Back returns to the conversation. |

Interactively, capture `sim shot <run id> credits` after opening Credits. For fixed French, choose it through `/language` before opening `settings.credits` and capture `credits-french`. `BillingIdentityProof` asserts the zero-Credits screen holds the amount, the notice and the three packs, and no other row. `LanguageMatrixFrSweep` opens Credits in French when it is named. The hosted app tests `FixtureLaunchTests.theCreditsScreenSellsEachPackAndAddsTheBoughtCredits`, `anApprovedAskToBuyAddsCreditsAndSaysSoOnlyOnTheOpenCreditsScreen` and `aRefusedPurchaseKeepsItsAppleRefundOfferUntilARefundIsRequested` cover the screen model, and `StoreKitCreditsStoreTests` runs the real StoreKit store against `EnduragentTests/StoreKit/CreditsPacks.storekit`. The package `CreditsPurchaseTests` owns which refusals leave a purchase unfinished and which finish it. `FixtureLaunchTests.creditsFailuresShowCatalogNotices` and `AccessSettingsTests.creditsResultsDiscardStaleSuccess` cover failed reads and clearing an earlier successful amount. The launch argument `-EnduragentFixtureCredits unavailable` scripts a failed Credits read.

## Gotchas

- Fixture mode starts available Credits at 200; `fixture:fail 402` changes its Credits result to zero. A bought pack adds 401 credits in fixture mode whichever pack is tapped. These proofs do not establish live spending or a real App Store purchase; RELEASE.md's Sandbox purchase step does.
- An approved Ask to Buy purchase settles in the background. The Added sentence shows only while Credits is open; opening Credits later shows the new amount and no sentence.
- Debug, Credits uses `debug.credits` on its link. Its developer labels are outside the athlete-screen proof, and Release builds omit them.
- Credits opened from Model access sits above Settings, and one Back returns to Settings. A conversation notice pushes its screen directly above the conversation, and one Back returns there. Capture the entry point used.

## Exhausted Credits keep the conversation

Run `BillingIdentityProof`. Its Credits conversation saves schedule memory with `fixture:teach`, then uses `fixture:fail 402`. The exhausted sentence offers only Buy Credits, `billing-identity-exhausted-conversation`. Buy Credits opens Credits with 0 credits, the exhausted sentence and the three packs, `billing-identity-zero-credits`, and one Back returns to the unchanged conversation. Relaunch retains the conversation notice with Buy Credits, the saved reply, the memory record and the message records. `testOutOfCreditsActionFitsInTheLongestTranslations` shows Buy Credits uncut in French and Dutch, `billing-identity-exhausted-conversation-fr` and `billing-identity-exhausted-conversation-nl`.

Package `CreditsClientTests.BillingIdentityTests` checks every real model request credential, saved model, memory tool output and reopened stores. Grant, claim and recovery use HTTP-stubbed worker replies through `Coach.credits`, including unavailable and failed-persistence cases. Hosted `BillingRouteTests` checks the fixture Credits call list and the Keychain items after onboarding, Settings, Credits and the Buy Credits route, from `credits` and from `build9-openrouter`. No route calls claim or recover, changes a Keychain item or starts model work. No proof contacts the live worker or OpenRouter.
