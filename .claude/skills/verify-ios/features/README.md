# Enduragent iPhone verification map

This directory is the maintained source for verifying what an athlete can do in the Enduragent iPhone app. Read the index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Build the checkout with `.claude/skills/verify-ios/helpers/sim.mjs build`.
- Create a run with `sim.mjs create <slug>` and keep the printed run id.
- Install the app with `sim.mjs install <run id>`.
- Run `sim.mjs doctor <run id>` and require exit 0.
- Launch with `sim.mjs launch <run id>` for interactive driving. A proof launches the app itself.
- Never drive a simulator that this run did not create.

## Driving conventions

- Every launch is a first launch, because fixture state lives in memory. Each recipe starts at the notice screen unless its preconditions say otherwise.
- Find controls by accessibility identifier. Use a visible label only where the feature file says the control has no identifier.
- Scripted steps run an existing proof with `sim.mjs test <run id> <Proof>`. Steps marked interactive use the iOS Simulator `control` tool with `device: <udid>` on every call.
- Treat every command and every quoted string as literal.
- Type `fixture` as the intervals.icu key. Any non-empty key connects in fixture mode.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- A scripted step's proof is the `Passed` summary plus its named attachment. An interactive step's proof is a `sim.mjs shot` before and after the action.
- Every proof run that reaches the chat also reads `fixture.requestCount` as `0 requests`.
- Record the feature ID and the entry point with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the athlete-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every athlete entry point.
3. `Driving it with sim.mjs and XCUITest` starts with `Preconditions:` and uses labeled bullets that pair each athlete action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only athlete paths, stable handles, required state, commands, and observable proof.

## Features

- [Onboarding](./onboarding.md) covers the notice, connecting or skipping intervals.icu, and the starter credits.
- [Chat](./chat.md) covers sending, replies, the working line, the slash list, `/plan`, and `New chat`.
- [Workout preview](./workout-preview.md) covers the `Confirmed preview` card with `Cancel` and `Add to calendar`.
- [History](./history.md) covers the chat list in the menu and reopening a chat.
- [Credits](./credits.md) covers the balance, the packs, and the tester note.
