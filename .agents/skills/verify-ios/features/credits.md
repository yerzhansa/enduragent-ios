# Credits

The athlete's Credits screen shows available Credits, the two packs, and the tester notice. Buying is disabled. Settings also offers Access method under Model access. A Credits notice under a turn opens this same screen through Buy Credits or Restore purchases.

## Sub-features

- `credits-balance` shows the fixture's `200 credits` in `credits.balance`.
- `credits-packs` shows 500 and 2000 credits, with disabled Buy buttons, in `credits.pack.icu.enduragent.credits.small` and `credits.pack.icu.enduragent.credits.large`.
- `credits-note` shows `Testers cannot buy packs yet.` in `credits.note`.
- `credits-unavailable` shows `Credits are unavailable right now. Try again later.` in `credits.notice` when loading fails.
- `credits-recovery` opens Credits from the turn's `chat.turn.buyCredits` or `chat.turn.restorePurchases` action without replacing the conversation.
- `credits-language` renders the title, amounts, pack rows, Buy, tester notice, and failure notice through the current language preference.

## How to get to it (user POV)

- Tap Settings, then Credits under Model access from the conversation.
- Choose Buy Credits or Restore purchases below a Credits-related turn notice.
- Receive starter Credits during [onboarding](./onboarding.md).
- Debug, Credits is a separate developer entry for grant, identity, and purchase diagnostics. It does not replace the athlete's Credits screen.

## Driving it with sim and XCUITest

Preconditions:

- Follow the [index](./README.md) setup. Interactive steps begin after onboarding.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim test <run id> CreditsProof` | `chat.settings`, then `settings.credits` under Model access, opens 200 credits, both packs, and the tester note, `06-credits`. |
| `sim test <run id> NoticeCopyProof` | `fixture:fail 402` offers Buy Credits; `fixture:fail 401` offers Restore purchases. Both actions open `credits.balance` and return to the conversation after one Back, `notice-copy-buy-credits-opens-credits`, `notice-copy-restore-purchases-opens-credits`. |

Interactively, inspect both Buy buttons as disabled and capture `sim shot <run id> credits-buy-disabled`. For fixed French, choose it through `/language` before opening `settings.credits` and capture `credits-french`. There is no dedicated XCUITest class for these two checks. The hosted app tests `creditsFailuresShowCatalogNotices` and `AccessSettingsTests.creditsResultsDiscardStaleSuccess` cover failed reads and clearing an earlier successful amount. The launch argument `-EnduragentFixtureCredits unavailable` scripts a failed Credits read.

## Gotchas

- Fixture mode omits StoreKit price lookup and starts available Credits at 200; `fixture:fail 402` with Credits selected changes its Credits result to zero. These proofs do not establish live prices, spending, purchases, or restore settlement.
- Restore purchases currently navigates to Credits. The button's label is not evidence of a restored transaction.
- Debug, Credits uses `debug.credits` on its link. Its developer labels and StoreKit actions are outside the athlete-screen proof.
- Credits opened from Model access sits above Settings, and one Back returns to Settings. A conversation notice pushes Credits directly above the conversation, and one Back returns there. Capture the entry point used.

## Access method in Settings

`AccessSettingsProof` covers the two choices, their saved marks, successful first sign-in with named model consent, cancelled sign-in, rejected callback, exchange failure, two taps joining held sign-in, failed choice and credential writes, starter provisioning, relaunch, recovery destinations, depleted Credits and unavailable reads. Attachments are named `access-settings-<result>-light` and capture each result. `AccessNoticeProof.testNotConfiguredOpensAccessMethod` covers the missing-access notice destination.

- `settings.accessMethod` opens the Access method screen under Model access.
- `access.credits` chooses Credits after starter setup persists its credential.
- `access.openRouter` is Sign in with OpenRouter. Successful sign-in marks OpenRouter after persistence; cancellation, callback rejection, exchange failure, and save failure keep the saved mark.
- `access.notice` shows availability or the latest choice outcome.
- `credits.switchToOpenRouter` opens this same screen without selecting a method.

Fixture launch arguments use `-EnduragentFixtureAccess` with `credits`, `openrouter`, `credits-needs-setup` or `openrouter-needs-credits`. OpenRouter launch states store the synthetic OpenRouter credential and saved model; the ordinary OpenRouter state also stores Credits. `-EnduragentFixtureCredits` accepts `ready`, `zero`, `unavailable`, `provisioning-failed` or `already-granted`. A minted grant persists the scripted credential through CredentialVault before returning. Keep launches never reseed either identity or the selection. `-EnduragentFixtureKeychain malformed-access` supplies an unreadable saved model selection.

Choose access method, Switch to OpenRouter and Sign in again recovery actions open this screen directly above the conversation. Buy Credits opens Credits with Buy disabled and the tester notice. These routes keep the conversation and the saved method.

## Separate billing identities

Run `BillingIdentityProof`. Its Credits conversation saves schedule memory with `fixture:teach`, then uses `fixture:fail 402`. The exhausted sentence offers switching without inviting a disabled purchase, with Buy Credits above Switch to OpenRouter. Switch to OpenRouter in the notice opens Access method with Credits still marked, and one Back returns to the unchanged conversation: `billing-identity-exhausted-conversation`, `billing-identity-notice-switch-keeps-credits` and `billing-identity-back-from-notice-switch`. Buy Credits opens zero Credits with disabled Buy and the tester notice. Switch to OpenRouter opens Access method with Credits still marked. Relaunch retains the conversation notice with both actions, saved reply, memory record and message records. `testOutOfCreditsActionsFitInTheLongestTranslations` shows both actions uncut in French and Dutch, `billing-identity-exhausted-conversation-fr` and `billing-identity-exhausted-conversation-nl`. The OpenRouter case uses `fixture:fail 401`, opens Sign in again without switching, attempts another turn and reopens with OpenRouter marked.

Package `CreditsClientTests.BillingIdentityTests` checks every real model request credential, saved model, memory tool output and reopened stores. Grant, claim and recovery use HTTP-stubbed worker replies through `Coach.credits`, including unavailable and failed-persistence cases. Hosted `BillingRouteTests` checks the existing fixture Credits call list after onboarding, Settings, Credits and each recovery route. No route calls claim or recover, changes selection or starts model work. Ready fixture launches store both identities. No proof contacts the live worker or OpenRouter.

`AccessOnboardingProof` also checks that leaving onboarding clears its result sentence before Settings opens Access method. Hosted `AccessOnboardingTests.failedStarterAndChoicesKeepPreviousAccess` owns that lifecycle regression for all failure rows.
