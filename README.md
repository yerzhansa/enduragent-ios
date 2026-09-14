# Enduragent for iPhone

This repository owns the iPhone app, local Swift coach package, and credits Worker. The app is an early shell. Phone credits screens and the final interface remain unfinished.

## Development

Use Node `24.20.0`, pnpm `11.24.0`, Xcode `26.6`, and XcodeGen `2.46.0`.

```sh
pnpm install --frozen-lockfile
pnpm check:catalogs
pnpm check:source
pnpm check:worker
pnpm test:worker
pnpm test:swift
pnpm check:worker-dry-run
xcodegen generate --spec apps/ios/project.yml
xcodebuild -project apps/ios/Enduragent.xcodeproj -scheme Enduragent -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

CI runs these focused checks on every pull request and every push to main. The dry run builds the TestFlight Worker without deploying. CI has no deployment credentials.

Swift live API tests are opt-in and skipped by `pnpm test:swift`. Optional REST test evidence is written only when `ENDURAGENT_TEST_EVIDENCE_DIRECTORY` names an existing test-owned directory.

## Source ownership

The baseline is [Enduragent commit 1a257829](https://github.com/yerzhansa/enduragent/commit/1a257829c6c041e8342a33374077fc244d3f2647). The four-file Worker redirect fix is preserved from [reviewed commit 14020d87](https://github.com/yerzhansa/enduragent/commit/14020d876018c8fbea5d4d2837862563b7967f3f).

The app and Worker keep their original paths and protocol. Repository ownership does not change the deployed Worker hostname, database, secrets, funding, or app identity placeholders.

The generated `Phrasebook.json` is the raw resource consumed by the Swift renderer. Native Apple String Catalog export and Xcode catalog-editor validation are not provided. App builds, bundled-resource equality, and Phrasebook runtime tests verify this representation.

The standalone localization generator and all 17 locale catalogs are pinned source imports. Update translations through an explicit reviewed import from the source repository. This repository owns catalog generation and the generated Swift resources. There is no automatic synchronization.

`migration-receipt.json` records original path digests and migration edits. It describes the imported snapshot and does not restrict future app or Worker changes. Historical fixture lineage has not been independently established by this import.

## Credits

The source is [Enduragent](https://github.com/yerzhansa/enduragent), licensed under MIT. Applicable upstream acknowledgements and license text are retained in [NOTICE.md](NOTICE.md).
