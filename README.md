# Enduragent for iPhone

This repository owns the iPhone app and local Swift coach package. The app is an early shell. Phone credits screens and the final interface remain unfinished.

## Development

Use Node `24.20.0`, pnpm `11.24.0`, Xcode `26.6`, XcodeGen `2.46.0`, and SwiftLint `0.65.1`.

```sh
pnpm install --frozen-lockfile
pnpm check:catalogs
pnpm check:source
pnpm lint:swift
pnpm check:format
pnpm test:swift
xcodegen generate --spec apps/ios/project.yml
xcodebuild -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

CI runs these focused checks on every pull request and every push to main.

`pnpm lint:swift` enforces the rules in `.swiftlint.yml`.

`pnpm check:format` runs `swift format lint --strict` with `.swift-format` on tracked Swift sources. `pnpm format:swift` writes that layout. The generated catalog is left to its generator.

Swift live API tests are opt-in and skipped by `pnpm test:swift`. Optional REST test evidence is written only when `ENDURAGENT_TEST_EVIDENCE_DIRECTORY` names an existing test-owned directory.

## Source ownership

The baseline is [Enduragent commit 1a257829](https://github.com/yerzhansa/enduragent/commit/1a257829c6c041e8342a33374077fc244d3f2647).

The app and local Swift coach package keep their original paths and protocol. Repository ownership does not change the app identity placeholders.

The generated `Phrasebook.json` is the raw resource consumed by the Swift renderer. Native Apple String Catalog export and Xcode catalog-editor validation are not provided. App builds, bundled-resource equality, and Phrasebook runtime tests verify this representation.

The standalone localization generator and all 17 locale catalogs are pinned source imports. Update translations through an explicit reviewed import from the source repository. This repository owns catalog generation and the generated Swift resources. There is no automatic synchronization.

`migration-receipt.json` records original path digests and migration edits. It describes the imported snapshot and does not restrict future app changes. Historical fixture lineage has not been independently established by this import.

## Credits

The source is [Enduragent](https://github.com/yerzhansa/enduragent), licensed under MIT. Applicable upstream acknowledgements and license text are retained in [NOTICE.md](NOTICE.md).
