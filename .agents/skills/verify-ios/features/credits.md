# Credits

The athlete's Credits screen shows available Credits, Switch to OpenRouter, and a notice when Credits run out or cannot load. The app sells no Credits: each iPhone gets starter Credits once, then the athlete switches to their own OpenRouter account. Settings opens Credits and Access method under Model access. A Credits notice under a turn offers only Switch to OpenRouter, which opens Access method.

## Sub-features

- `credits-balance` shows the fixture's `200 credits` in `credits.balance`.
- `credits-unavailable` shows `Credits are unavailable right now. Try again later.` in `credits.notice` when loading fails. At zero Credits the same element shows the out-of-Credits sentence.
- `credits-switch` offers Switch to OpenRouter in `credits.switchToOpenRouter`, which opens the Access method screen without selecting a method.
- `credits-recovery` offers `chat.turn.switchToOpenRouter` under an out-of-Credits or rejected-Credits turn. It opens Access method above the conversation without replacing it.
- `credits-language` renders the title, amount, Switch to OpenRouter, and failure notice through the current language preference.

## How to get to it (user POV)

- Tap Settings, then Credits under Model access from the conversation.
- Receive starter Credits during [onboarding](./onboarding.md).
- Debug, Credits is a separate developer entry for grant, identity, and purchase diagnostics. Debug builds alone contain it and its StoreKit purchase coordinator. It does not replace the athlete's Credits screen.

## Driving it with sim and XCUITest

Preconditions:

- Follow the [index](./README.md) setup. Interactive steps begin after onboarding.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim test <run id> CreditsProof` | `chat.settings`, then `settings.credits` under Model access, opens 200 credits and Switch to OpenRouter, `06-credits`. |
| `sim test <run id> NoticeCopyProof` | `fixture:fail 402` and `fixture:fail 401` each offer Switch to OpenRouter and no Try again, `notice-copy-credits-exhausted`, `notice-copy-access-rejected`. `BillingIdentityProof` and the hosted `FixtureLaunchTests.creditsNoticeReturnsToConversationAfterOneBack` prove the action opens Access method and one Back returns to the conversation. |

Interactively, check that the screen holds only the amount, Switch to OpenRouter, and any notice, and capture `sim shot <run id> credits`. For fixed French, choose it through `/language` before opening `settings.credits` and capture `credits-french`. `BillingIdentityProof` asserts the zero-Credits screen holds exactly three rows, and `LanguageMatrixFrSweep` opens Credits in French when it is named. The hosted app tests `FixtureLaunchTests.creditsFailuresShowCatalogNotices` and `AccessSettingsTests.creditsResultsDiscardStaleSuccess` cover failed reads and clearing an earlier successful amount. The launch argument `-EnduragentFixtureCredits unavailable` scripts a failed Credits read.

## Gotchas

- Fixture mode starts available Credits at 200; `fixture:fail 402` with Credits selected changes its Credits result to zero. These proofs do not establish live spending.
- Debug, Credits uses `debug.credits` on its link. Its developer labels and StoreKit actions are outside the athlete-screen proof, and Release builds omit them.
- Credits opened from Model access sits above Settings, and one Back returns to Settings. A conversation notice pushes Access method directly above the conversation, and one Back returns there. Capture the entry point used.

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

Run `BillingIdentityProof`. Its Credits conversation saves schedule memory with `fixture:teach`, then uses `fixture:fail 402`. The exhausted sentence offers Switch to OpenRouter as its only action. It opens Access method with Credits still marked, and one Back returns to the unchanged conversation: `billing-identity-exhausted-conversation`, `billing-identity-notice-switch-keeps-credits` and `billing-identity-back-from-notice-switch`. Settings, then Credits, shows 0 credits, the exhausted sentence and one Switch to OpenRouter, `billing-identity-zero-credits`. Switch to OpenRouter opens Access method with Credits still marked. Relaunch retains the conversation notice with its action, saved reply, memory record and message records. `testOutOfCreditsActionsFitInTheLongestTranslations` shows the action uncut in French and Dutch, `billing-identity-exhausted-conversation-fr` and `billing-identity-exhausted-conversation-nl`. The OpenRouter case uses `fixture:fail 401`, opens Sign in again without switching, attempts another turn and reopens with OpenRouter marked.

Package `CreditsClientTests.BillingIdentityTests` checks every real model request credential, saved model, memory tool output and reopened stores. Grant, claim and recovery use HTTP-stubbed worker replies through `Coach.credits`, including unavailable and failed-persistence cases. Hosted `BillingRouteTests` checks the existing fixture Credits call list after onboarding, Settings, Credits and the Choose access method and Switch to OpenRouter recovery routes. No route calls claim or recover, changes selection or starts model work. Ready fixture launches store both identities. No proof contacts the live worker or OpenRouter.

`AccessOnboardingProof` also checks that leaving onboarding clears its result sentence before Settings opens Access method. Hosted `AccessOnboardingTests.failedStarterAndChoicesKeepPreviousAccess` owns that lifecycle regression for all failure rows.
