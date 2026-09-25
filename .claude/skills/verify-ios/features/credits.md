# Credits

The menu's Credits screen shows the athlete's credit balance and the credit packs, and tells testers that they cannot buy packs yet.

## Sub-features

- `credits-balance` shows `200 credits` in `credits.balance`.
- `credits-packs` shows `credits.pack.icu.enduragent.credits.small` with `500 credits` and `credits.pack.icu.enduragent.credits.large` with `2000 credits`, each with a disabled `Buy`.
- `credits-note` shows `Testers cannot buy packs yet.` in `credits.note`.

## How to get to it (user POV)

- In the chat, choose `Menu`, then `Credits`.
- The starter grant during onboarding is covered in [onboarding.md](./onboarding.md).

## Driving it with sim.mjs and XCUITest

Preconditions:

- `sim.mjs doctor <run id>` exits 0 and the app is installed.
- For interactive steps, the app is on the chat after onboarding.

- **Open credits.** Tap `chat.sidebar`, then `sidebar.credits`. Run `sim.mjs test <run id> CreditsProof`. `credits.balance` reads `200 credits`, `credits.note` reads `Testers cannot buy packs yet.`, and both pack rows exist. Attachment `06-credits` shows the screen.
- **Buy is disabled.** This step is interactive. Tap `Buy` on the 500-credit row. Nothing changes and the button stays dimmed. Capture `sim.mjs shot <run id> credits-buy-disabled` after the tap.

## Gotchas

- Fixture mode skips the StoreKit price lookup, so pack rows show credits without a price. A fixture run cannot verify prices.
- The fixture balance stays at 200 credits after any number of chats. Spending is not modeled.
- `Debug`, then `Credits`, opens a developer screen. It is not this feature and is not proof of it.
