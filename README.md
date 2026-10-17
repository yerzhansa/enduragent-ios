# Enduragent for iPhone

This repository owns the iPhone app and local Swift coach package. The app is an early shell. Phone credits screens and the final interface remain unfinished.

## Development

Use Xcode `26.6`, XcodeGen `2.46.0`, and SwiftLint `0.65.1`. Run `make` from the repository root.

```sh
make check-catalogs
make check-source
make check-coverage
make lint-swift
make check-format
make test-swift
swift build -c release --package-path apps/ios/Packages/EnduragentCoach
make project
xcodebuild -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

CI runs the tool tests, source checks, package tests, app tests, and Release builds on every pull request and every push to main. `make test-app` runs the app tests on the first available iPhone simulator. Set `DERIVED_DATA` to choose the build folder and `ONLY=EnduragentTests/<Suite>` to run one suite.

`make check-catalogs` runs `make generate-catalogs` and fails when a generated catalog file changes. `make check-source` runs the source checker. `make lint-swift` enforces the rules in `.swiftlint.yml`.

Run `make test-tools` when you change `tools/` or `.swiftlint.yml`. The Swift package in `tools/` holds the checker, the catalog generator, the `verify-ios` helpers, the upgrade-store generator, and the tests of the custom SwiftLint rules. CI runs this gate before `make check-source` on every pull request.

`make check-format` runs `swift format lint --strict` with `.swift-format` on tracked Swift sources. `make format-swift` writes that layout. The generated catalog is left to its generator.

Swift live API tests are opt-in and skipped by `make test-swift`.

The live checks live in their own test target, `EnduragentCoachLiveChecks`, and reach intervals.icu only through the app's `IntervalsRESTClient`. Each check runs only when its Make target sets `ENDURAGENT_LIVE`, so `make test-swift` runs the target's offline tests and skips every check that would reach the network.

`make live-reads` reads the intervals.icu account of the key in the Mac Keychain through the app's read code and saves every raw response and decoded value under `LIVE_LOGS`. `make live-coach` runs the coach scenario suite against the built-in model with billed calls, stops before its total in `LIVE_LOGS/spend.tsv` would pass the cap the check sets, and prints that total against the cap. `make live-reads` needs the Keychain item `enduragent-m3-intervals-api-key`, and `make live-coach` needs it and `enduragent-m3-openrouter-key`; each check reads them at run time and stops at once when one is missing. `LIVE_LOGS` defaults to `~/Library/Logs/enduragent-m3/LIVE`. Neither check runs in CI or in `make test-swift`.

`make live-seed` writes six weeks of synthetic training and wellness to the intervals.icu test account of the same Keychain item, after checking that the account holds no activity the seed did not write, and records the athlete id, every activity id and every wellness date in `LIVE_LOGS/seed/ledger.tsv`; a rerun adds only what is missing. Both targets stop without a change when the key belongs to another athlete than the ledger names. `make live-unseed` deletes only those activities that the account still lists with the `[synthetic]` name prefix and the seed's `external_id` prefix, names in its report each ledger activity it skipped because it no longer matches, clears only the wellness values that still equal what the seed wrote and reads them back empty, and confirms that no seeded activity is left. `make live-seed` also adds ten calendar entries dated from the day it runs, by bulk upsert on their `external_id`: an athlete-owned workout, a coach-tagged race, a note with an empty name, a past workout, and the coach-created future workouts T1, T2, K, T3, T4 and T5. A rerun adds only the entries the calendar no longer lists. `make live-unseed` deletes every calendar entry the ledger names whose `external_id` still matches, and confirms that none is left. Neither runs in CI or in `make test-swift`.

`make live-calendar` writes to the same test calendar through the app's `write(_:)` and stops before any write when the key's athlete is not the one `LIVE_LOGS/seed/ledger.tsv` names. It reads the seeded entries back, adds a 15-minute repeat ride and a strength session and reads them back, sends one add twice, edits each workout field alone, moves two adds by 30 and 200 days and sends them again, sends an add with an unknown category, deletes one event twice, and loses the answer of one add, one edit and one delete before settling each by one read. It then approves one mixed review through `WorkoutReviewDesk`: two adds, an edit and a delete of events the check created, beside a kept workout it also created. The approval must send four write requests in card order, save four Receipts and a completed outcome, hold one lease that ends finished, and leave the calendar as reviewed with the kept workout unchanged. Each event it creates is recorded in the ledger before the write, identified by its `external_id`, and deleted at the end. A field that intervals.icu stores differently from what was sent fails the check unless `apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures/intervals-rewrites.json` lists that rewrite. The check writes `calendar.md` and every raw answer under `LIVE_LOGS/calendar`, fails when a saved file holds the key, and costs no Credits.

`make lint-swift`, `make test-tools`, and `make test-swift` pass `ARGS` to their command, for example `make test-swift ARGS=--disable-sandbox`.

## Source ownership

The baseline is [Enduragent commit 1a257829](https://github.com/yerzhansa/enduragent/commit/1a257829c6c041e8342a33374077fc244d3f2647).

The app and local Swift coach package keep their original paths and protocol. Repository ownership does not change the app identity placeholders.

The generated `Phrasebook.json` is the raw resource consumed by the Swift renderer. Native Apple String Catalog export and Xcode catalog-editor validation are not provided. App builds, bundled-resource equality, and Phrasebook runtime tests verify this representation.

The 17 locale catalogs are pinned source imports. Update translations through an explicit reviewed import from the source repository. This repository owns the catalog generator, the Swift package in `tools`, and the generated Swift resources. There is no automatic synchronization.

`migration-receipt.json` records original path digests and migration edits. It describes the imported snapshot and does not restrict future app changes. Historical fixture lineage has not been independently established by this import.

## Credits

The source is [Enduragent](https://github.com/yerzhansa/enduragent), licensed under MIT. Applicable upstream acknowledgements and license text are retained in [NOTICE.md](NOTICE.md).
