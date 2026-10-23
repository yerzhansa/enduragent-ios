# npm fixture generator

The generator runs the npm packages at one pinned revision and writes the fixtures that the planning tests compare against. The fixtures are in `apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures/plan/`.

The pinned revision is `d192cb974e715e1527645e0acf0d8353ed4d0edc` of the desktop repository. The generator needs Node `v24.11.1` and a checkout of that revision with its `node_modules` installed. The repository itself has no Node, no `package.json` and no lockfile. Every npm module resolves inside the checkout.

## Commands

Write every fixture file and `manifest.json`:

```sh
make plan-fixtures NPM=/path/to/the/pinned/checkout
```

Compare the committed fixtures with a fresh run, and write nothing:

```sh
make plan-fixtures-check NPM=/path/to/the/pinned/checkout
```

The check prints one line for each file that differs, is missing or is not made by the generator, and exits with status 1.

Both targets run `node tools/npm-fixtures/run.mjs`, so the first `node` on `PATH` must be `v24.11.1`. Neither target is part of CI. CI has no Node and no npm checkout.

## What a run does

1. `run.mjs` refuses any Node other than `v24.11.1`, before any TypeScript loads.
2. The checkout must be at the pinned revision with no local changes.
3. `corepack pnpm` from the Node folder rebuilds `@enduragent/sport-cycling`, `@enduragent/core` and every workspace package they depend on, with the network off. Pass `--corepack <path>` to use another `corepack`.
4. The build must leave every tracked file of the checkout unchanged.
5. `freeze.mts` replaces `Date` before any npm module loads. After the npm modules load, any call to `randomUUID` stops the run.
6. `cases.mts` holds the input space. Each function case is an argument object that the matching tool's schema accepts. `generate.mts` runs every case, then writes every file at once.

Each refusal prints `npm-fixtures: <reason>`, exits with status 1 and writes nothing.

## Files

Each fixture file opens with a header line that names the revision and the npm function. Each case is one line. The last line closes the file. No file reaches 4,000,000 bytes, so the plan drafts are split into `plan-draft-1.json`, `plan-draft-2.json` and so on.

`manifest.json` records the Node and ICU versions, the `ai` and `zod` versions, the hash of every file under the `dist` folders the run loads, the seed of the case generator, the hash of the four generator files, and the hash and case count of each fixture file. For `tool-inputs.json` it also counts the cases of each tool.

`PlanFixtureProvenanceTests` checks the committed fixtures against `manifest.json` and the generator files on every `make test-swift`. A fixture edited together with its hash in the manifest passes that test. Only `make plan-fixtures-check` catches it.

## Change the fixtures

1. Change `cases.mts` or the other generator files.
2. Run `make plan-fixtures NPM=…`.
3. Commit the generator files, every fixture file and `manifest.json` together.

Never edit a fixture by hand.

## Move the pin

1. Check out the new revision of the desktop repository and install its `node_modules`.
2. Change the revision in `generate.mts` and in `PlanFixtures.swift`, and the Node version in `run.mjs` if the new revision needs another one.
3. Run `make plan-fixtures NPM=…` and commit the result as above.

## Hooks for the refusals

- `--probe random-uuid` runs one `buildPlanSkeleton` call without an id after the guards. The run stops at `randomUUID`.
- `--probe outside-schema` checks one `get_sample_week` case with `sessionsPerWeek` 7 after the guards. The run stops because the schema refuses it.

A normal run never runs a probe.
