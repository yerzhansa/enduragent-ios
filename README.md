# Enduragent for iPhone

This repository owns the iPhone app and local Swift coach package. The app is an early shell. Phone credits screens and the final interface remain unfinished.

## Development

Use Xcode `26.6`, XcodeGen `2.46.0`, and SwiftLint `0.65.1`. Run `make` from the repository root.

```sh
make check-catalogs
make check-source
make lint-swift
make check-format
make test-swift
swift build -c release --package-path apps/ios/Packages/EnduragentCoach
xcodegen generate --spec apps/ios/project.yml
xcodebuild -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

CI runs the tool tests, source checks, package tests, app tests, and Release builds on every pull request and every push to main. To run the app tests locally, choose an iPhone destination from `xcodebuild -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -showdestinations`, then run:

```sh
xcodebuild test -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,arch=arm64,id=<iPhone destination ID>' -derivedDataPath DerivedData -only-testing:EnduragentTests CODE_SIGNING_ALLOWED=NO
```

`make check-catalogs` runs `make generate-catalogs` and fails when a generated catalog file changes. `make check-source` runs the source checker. `make lint-swift` enforces the rules in `.swiftlint.yml`.

Run `make test-tools` when you change `tools/` or `.swiftlint.yml`. The Swift package in `tools/` holds the checker, the catalog generator, the `verify-ios` helpers, the upgrade-store generator, and the tests of the custom SwiftLint rules. CI runs this gate before `make check-source` on every pull request.

`make check-format` runs `swift format lint --strict` with `.swift-format` on tracked Swift sources. `make format-swift` writes that layout. The generated catalog is left to its generator.

Swift live API tests are opt-in and skipped by `make test-swift`.

`make lint-swift`, `make test-tools`, and `make test-swift` pass `ARGS` to their command, for example `make test-swift ARGS=--disable-sandbox`.

## Source ownership

The baseline is [Enduragent commit 1a257829](https://github.com/yerzhansa/enduragent/commit/1a257829c6c041e8342a33374077fc244d3f2647).

The app and local Swift coach package keep their original paths and protocol. Repository ownership does not change the app identity placeholders.

The generated `Phrasebook.json` is the raw resource consumed by the Swift renderer. Native Apple String Catalog export and Xcode catalog-editor validation are not provided. App builds, bundled-resource equality, and Phrasebook runtime tests verify this representation.

The 17 locale catalogs are pinned source imports. Update translations through an explicit reviewed import from the source repository. This repository owns the catalog generator, the Swift package in `tools`, and the generated Swift resources. There is no automatic synchronization.

`migration-receipt.json` records original path digests and migration edits. It describes the imported snapshot and does not restrict future app changes. Historical fixture lineage has not been independently established by this import.

## Credits

The source is [Enduragent](https://github.com/yerzhansa/enduragent), licensed under MIT. Applicable upstream acknowledgements and license text are retained in [NOTICE.md](NOTICE.md).
