# Credits

The athlete's Credits screen shows available Credits, the two packs, and the tester notice. Buying is disabled. A Credits notice under a turn opens this same screen through Buy Credits or Restore purchases.

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

## Driving it with sim.mjs and XCUITest

Preconditions:

- Follow the [index](./README.md) setup. Interactive steps begin after onboarding.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> CreditsProof` | `chat.settings`, then `settings.credits` under Model access, opens 200 credits, both packs, and the tester note, `06-credits`. |
| `sim.mjs test <run id> NoticeCopyProof` | `fixture:fail 402` offers Buy Credits; `fixture:fail 401` offers Restore purchases. Both actions open `credits.balance` and return to the conversation after one Back, `notice-copy-buy-credits-opens-credits`, `notice-copy-restore-purchases-opens-credits`. |

Interactively, inspect both Buy buttons as disabled and capture `sim.mjs shot <run id> credits-buy-disabled`. For fixed French, choose it through `/language` before opening `settings.credits` and capture `credits-french`. There is no dedicated XCUITest class for these two checks. The hosted app test `creditsFailuresShowCatalogNotices` covers the unavailable notice; fixture directives do not fail the Credits client.

## Gotchas

- Fixture mode omits StoreKit price lookup and keeps available Credits at 200. These proofs do not establish live prices, spending, purchases, or restore settlement.
- Restore purchases currently navigates to Credits. The button's label is not evidence of a restored transaction.
- Debug, Credits uses `debug.credits` on its link. Its developer labels and StoreKit actions are outside the athlete-screen proof.
- Credits opened from Model access sits above Settings, and one Back returns to Settings. A conversation notice pushes Credits directly above the conversation, and one Back returns there. Capture the entry point used.
