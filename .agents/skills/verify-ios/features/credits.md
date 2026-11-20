# Credits

The athlete's Credits screen shows available Credits, the three Credits packs with their App Store prices and a Buy button each, the outcome of the last purchase, Switch to OpenRouter, and a notice when Credits run out or cannot load. Each iPhone gets starter Credits once, and the athlete buys more on this screen only. Settings opens Credits and Access method under Model access. The out-of-Credits notice under a turn offers Buy Credits, which opens this screen, then Switch to OpenRouter, which opens Access method.

## Sub-features

- `credits-balance` shows the fixture's `200 credits` in `credits.balance`.
- `credits-unavailable` shows `Credits are unavailable right now. Try again later.` in `credits.notice` when loading fails. At zero Credits the same element shows the out-of-Credits sentence.
- `credits-packs` lists `401 credits · $4.99`, `802 credits · $9.99` and `1,606 credits · $19.99` in `credits.pack.<product id>`, each with `credits.buy.<product id>`. While a purchase runs, its row shows a spinner and the other Buy buttons are disabled.
- `credits-purchase` shows the purchase outcome in `credits.purchaseNotice`: `Added 401 credits`; `Added 401 credits. The coach now uses Credits.` when the access method was an OpenRouter account and the purchase switched it; the pending, purchase-failed, not-added-yet and can't-be-added sentences; nothing after the athlete closes Apple's payment sheet. The can't-be-added sentence offers `credits.purchaseAction`, Ask Apple for a refund, which opens Apple's refund sheet.
- `credits-not-for-sale` shows `Credits can't be bought right now. Try again later.` in `credits.notForSale` and no Buy button when the catalog has purchases off or the App Store returns no prices.
- `credits-switch` offers Switch to OpenRouter in `credits.switchToOpenRouter`, which opens the Access method screen without selecting a method.
- `credits-recovery` offers `chat.turn.buyCredits` and `chat.turn.switchToOpenRouter` under an out-of-Credits turn, and `chat.turn.switchToOpenRouter` under a rejected-Credits turn. Each opens its screen above the conversation without replacing it.
- `credits-language` renders the title, amount, pack rows, Buy, purchase sentences, Switch to OpenRouter, and failure notice through the current language preference.

## How to get to it (user POV)

- Tap Settings, then Credits under Model access from the conversation.
- Tap Buy Credits under an out-of-Credits turn.
- Receive starter Credits during [onboarding](./onboarding.md).
- Debug, Credits is a separate developer entry for grant and identity diagnostics. It has no purchase controls and does not replace the athlete's Credits screen.

## Driving it with sim and XCUITest

Preconditions:

- Follow the [index](./README.md) setup. Interactive steps begin after onboarding.

`-EnduragentFixturePurchase` sets what the fake App Store and the fake Credits service answer to a Buy tap: `added` (the default), `pending`, `cancel`, `fail`, `not-added-yet` (the Credits service is unavailable, so the purchase stays unfinished), `refused` (the Credits service refuses for good, so the purchase is finished and Ask Apple for a refund appears) or `not-for-sale` (the catalog has purchases off).

| Action and command | Observable result and attachment |
| --- | --- |
| `sim test <run id> CreditsProof` | `chat.settings`, then `settings.credits` under Model access, opens 200 credits, the three packs with enabled Buy buttons and Switch to OpenRouter, `06-credits`. |
| `sim test <run id> CreditsPurchaseProof` | At zero Credits, `fixture:fail 402` offers Buy Credits, which opens Credits; Buy adds 401 credits and the coach replies, `purchase-out-of-credits`, `purchase-credits-screen`, `purchase-added`, `purchase-reply-on-credits`. From an OpenRouter account, Buy switches the coach to Credits, so the AI-provider consent for the built-in model opens at once; after Agree, Access method marks Credits and Credits shows 601 credits, `purchase-switched-asks-consent`, `purchase-access-method-credits`. Each other outcome shows its sentence, `purchase-pending`, `purchase-cancel`, `purchase-fail`, `purchase-not-added-yet`, `purchase-refused`, `purchase-refund-requested`, `purchase-not-for-sale`. |
| `sim test <run id> NoticeCopyProof` | `fixture:fail 402` offers Buy Credits and Switch to OpenRouter and no Try again; Buy Credits opens Credits at 0 credits, `notice-copy-credits-exhausted`, `notice-copy-buy-credits-opens-credits`. `fixture:fail 401` offers Switch to OpenRouter, `notice-copy-access-rejected`. `BillingIdentityProof` and the hosted `FixtureLaunchTests.creditsNoticeReturnsToConversationAfterOneBack` prove the actions open their screens and one Back returns to the conversation. |

Interactively, capture `sim shot <run id> credits` after opening Credits. For fixed French, choose it through `/language` before opening `settings.credits` and capture `credits-french`. `BillingIdentityProof` asserts the zero-Credits screen holds exactly six rows: the amount, the notice, three packs and Switch to OpenRouter. `LanguageMatrixFrSweep` opens Credits in French when it is named. The hosted app tests `FixtureLaunchTests.theCreditsScreenSellsEachPackAndAddsTheBoughtCredits`, `anApprovedAskToBuyAddsCreditsAndSaysSoOnlyOnTheOpenCreditsScreen` and `aRefusedPurchaseKeepsItsAppleRefundOfferUntilARefundIsRequested` cover the screen model, and `StoreKitCreditsStoreTests` runs the real StoreKit store against `EnduragentTests/StoreKit/CreditsPacks.storekit`. The package `CreditsPurchaseTests` owns which refusals leave a purchase unfinished, which finish it, and the switch to Credits. `FixtureLaunchTests.creditsFailuresShowCatalogNotices` and `AccessSettingsTests.creditsResultsDiscardStaleSuccess` cover failed reads and clearing an earlier successful amount. The launch argument `-EnduragentFixtureCredits unavailable` scripts a failed Credits read.

## Gotchas

- Fixture mode starts available Credits at 200; `fixture:fail 402` with Credits selected changes its Credits result to zero. A bought pack adds 401 credits in fixture mode whichever pack is tapped. These proofs do not establish live spending or a real App Store purchase; RELEASE.md's Sandbox purchase step does.
- A purchase from an OpenRouter account switches the coach to Credits, and the consent screen for the built-in model replaces the conversation at once, so the `The coach now uses Credits.` sentence is not on screen in that flow. Hosted and package tests own that sentence.
- An approved Ask to Buy purchase settles in the background. The Added sentence shows only while Credits is open; opening Credits later shows the new amount and no sentence.
- Debug, Credits uses `debug.credits` on its link. Its developer labels are outside the athlete-screen proof, and Release builds omit them.
- Credits opened from Model access sits above Settings, and one Back returns to Settings. A conversation notice pushes its screen directly above the conversation, and one Back returns there. Capture the entry point used.

## Access method in Settings

`AccessSettingsProof` covers the two choices, their saved marks, successful first sign-in with named model consent, cancelled sign-in, rejected callback, exchange failure, two taps joining held sign-in, failed choice and credential writes, starter provisioning, relaunch, recovery destinations, depleted Credits and unavailable reads. `testDepletedAndUnavailableCreditsOfferTheAccessScreen` opens Credits at zero and after a failed read, and Switch to OpenRouter opens Access method with Credits still marked. `testRejectedAccessRecoveryPreservesTheConversation` follows `fixture:fail 401`: with Credits, Switch to OpenRouter opens Access method; with OpenRouter, Sign in again cancels in place. Both keep the conversation and the saved method through relaunch. Attachments are named `access-settings-<result>` and capture each result. `AccessNoticeProof.testNotConfiguredOpensAccessMethod` covers the missing-access notice destination.

- `settings.accessMethod` opens the Access method screen under Model access.
- `access.credits` chooses Credits after starter setup persists its credential.
- `access.openRouter` is Sign in with OpenRouter. Successful sign-in marks OpenRouter after persistence; cancellation, callback rejection, exchange failure, and save failure keep the saved mark.
- `access.notice` shows availability or the latest choice outcome.
- `credits.switchToOpenRouter` opens this same screen without selecting a method.

Fixture launch arguments use `-EnduragentFixtureAccess` with `credits`, `openrouter`, `catalog-openrouter`, `missing-openrouter`, `rejected-openrouter`, `synced-openrouter`, `credits-needs-setup` or `openrouter-needs-credits`. OpenRouter launch states store the synthetic OpenRouter credential and saved model; the ordinary OpenRouter state also stores Credits. `-EnduragentFixtureCredits` accepts `ready`, `zero`, `unavailable`, `provisioning-failed` or `already-granted`. A minted grant persists the scripted credential through CredentialVault before returning. Keep launches never reseed either identity or the selection. `-EnduragentFixtureKeychain malformed-access` supplies an unreadable saved model selection.

The Choose access method and Switch to OpenRouter recovery actions open this screen directly above the conversation. Sign in again starts the OpenRouter sign-in without leaving the conversation. These routes keep the conversation and the saved method.

## Separate billing identities

Run `BillingIdentityProof`. Its Credits conversation saves schedule memory with `fixture:teach`, then uses `fixture:fail 402`. The exhausted sentence offers Buy Credits, then Switch to OpenRouter. Switch to OpenRouter opens Access method with Credits still marked, and one Back returns to the unchanged conversation: `billing-identity-exhausted-conversation`, `billing-identity-notice-switch-keeps-credits` and `billing-identity-back-from-notice-switch`. Buy Credits opens Credits with 0 credits, the exhausted sentence, the three packs and one Switch to OpenRouter, `billing-identity-zero-credits`. Switch to OpenRouter opens Access method with Credits still marked. Relaunch retains the conversation notice with its actions, saved reply, memory record and message records. `testOutOfCreditsActionsFitInTheLongestTranslations` shows both actions uncut in French and Dutch, `billing-identity-exhausted-conversation-fr` and `billing-identity-exhausted-conversation-nl`. The OpenRouter case uses `fixture:fail 401`, opens Sign in again without switching, attempts another turn and reopens with OpenRouter marked.

Package `CreditsClientTests.BillingIdentityTests` checks every real model request credential, saved model, memory tool output and reopened stores. Grant, claim and recovery use HTTP-stubbed worker replies through `Coach.credits`, including unavailable and failed-persistence cases. Hosted `BillingRouteTests` checks the existing fixture Credits call list after onboarding, Settings, Credits and the Buy Credits, Choose access method and Switch to OpenRouter recovery routes. No route calls claim or recover, changes selection or starts model work. Ready fixture launches store both identities. No proof contacts the live worker or OpenRouter.

`AccessOnboardingProof` also checks that leaving onboarding clears its result sentence before Settings opens Access method. Hosted `AccessOnboardingTests.failedStarterAndChoicesKeepPreviousAccess` owns that lifecycle regression for all failure rows.
