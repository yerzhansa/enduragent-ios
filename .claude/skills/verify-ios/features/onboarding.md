# Onboarding

A first launch shows the health notice, then lets the athlete connect intervals.icu with an API key or skip it, then grants starter credits and opens the chat.

## Sub-features

- `onboarding-notice` shows the health notice and `Continue`.
- `onboarding-connect` accepts a key and shows the athlete's name, Fitness, Fatigue, and Form.
- `onboarding-connect-empty` rejects an empty key with `intervals.icu did not accept that key`.
- `onboarding-skip` continues without intervals.icu.
- `onboarding-starter` shows the starter grant and opens the chat with `Start chatting`.

## How to get to it (user POV)

- Open the app. Every fixture launch starts here.
- On the connect screen, enter a key and choose `Connect`.
- On the connect screen, choose `Skip for now`.

## Driving it with sim.mjs and XCUITest

Preconditions:

- `sim.mjs doctor <run id>` exits 0 and the app is installed.
- For interactive steps, `sim.mjs launch <run id>` has run and the notice is on screen.

- **Notice.** Open the app. Run `sim.mjs test <run id> InstallOpenProof`. The run passes and attachment `01-install-open` shows `Training suggestions, not medical advice. Check with a doctor before big changes.` above `Continue`.
- **Connect with a key.** Choose `Continue` (`notice.continue`), type `fixture` into `connect.apiKey`, and choose `Connect` (`connect.connect`). Run `sim.mjs test <run id> ConnectIntervalsProof`. `connect.athleteName` reads `Ada Kovač`, `connect.fitness` reads `Fitness 42`, `connect.fatigue` reads `Fatigue 49`, and `connect.form` reads `Form -7`. Attachment `02-connect-intervals` shows them.
- **Empty key.** This step is interactive. Leave `connect.apiKey` empty and tap `connect.connect`. A row reading `intervals.icu did not accept that key` appears between `Connect` and `Skip for now`. Capture it with `sim.mjs shot <run id> connect-empty-key`.
- **Starter credits.** After connecting, choose `Continue` (`connect.continue`). Run `sim.mjs test <run id> StarterCreditsProof`. `starter.credits` reads `200 credits` and `starter.start` exists. Attachment `03-starter-credits` shows both.
- **Skip.** This step is interactive. Tap `connect.skip`, wait for `200 credits` and `Start chatting`, then tap `starter.start`. The chat opens with the greeting `Hello.` and no name. Capture it with `sim.mjs shot <run id> skip-chat`.
- **Into the chat with no network.** Run `sim.mjs test <run id> FirstConversationProof`. A pass means onboarding reached `chat.composer` with `Hello, Ada.`, two replies arrived, and `fixture.requestCount` read `0 requests`. Attachment `04-first-conversation` shows the chat.

## Gotchas

- `sim.mjs launch` always passes `-EnduragentFixture first-week`. A bare `simctl launch` without it starts the live app, which uses the real keychain and calls the credits worker at the starter step.
- A relaunch returns to the notice, because fixture state lives in memory. The live app reopens in the chat instead, which a fixture run cannot show.
- Any non-empty key connects in fixture mode, so a connect proof does not prove key validation.
- `starter.progress` with `Requesting starter credits` shows only until the fake grant resolves, which is too fast to capture.
- A fresh simulator can show a `Ready for Apple Intelligence` banner over the top of the screen for a few seconds. Wait and capture again.
