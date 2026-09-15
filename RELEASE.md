# iOS TestFlight release

This is the iPhone upload path. The Railway image runbook does not apply.

## Identity

Read `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from `apps/ios/project.yml`. Do not hardcode the next version in a script.
First TestFlight is `0.1.0` `(1)`.
Bundle id is `icu.enduragent.app`.
Team is `FA494ACVTF`.
Display name is `Enduragent`.

`CREDITS_WORKER_BASE` is a build setting. First TestFlight uses `https://enduragent-credits-testflight.yerzhan-st.workers.dev`.
`OPENROUTER_MODEL` is a build setting. First TestFlight uses `deepseek/deepseek-v4.1-flash-20260910`.

## Lane

The first upload is from the operator Mac with Xcode automatic signing.
Do not merge a GitHub Actions upload workflow until the operator approves that specific workflow PR.

## Archive on the operator Mac

```sh
xcodegen generate --spec apps/ios/project.yml
xcodebuild -project apps/ios/Enduragent.xcodeproj -scheme Enduragent \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/Enduragent.xcarchive \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=FA494ACVTF archive
xcodebuild -exportArchive \
  -archivePath /tmp/Enduragent.xcarchive \
  -exportPath /tmp/Enduragent-export \
  -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates
```

`ExportOptions.plist` must set `method` to `app-store-connect`, `signingStyle` to `automatic`, and `teamID` to `FA494ACVTF`.

The IPA must embed an App Store profile: `get-task-allow` false, no device list, `beta-reports-active` true.

## App Store Connect

Create the app record named `Enduragent` with bundle id `icu.enduragent.app` before the first upload.
Use the developer-only Apple ID.

Upload with an App Store Connect API key. Put `AuthKey_<KEYID>.p8` in `~/.appstoreconnect/private_keys/`. Never commit the key.

```sh
xcrun altool --upload-app --type ios \
  --file /tmp/Enduragent-export/Enduragent.ipa \
  --apiKey KEYID \
  --apiIssuer ISSUER
```

Create TestFlight group `Athletes`. The operator iPhone is the first tester.

## Rollback

Expire the build in TestFlight. Do not delete the app record.

## Later builds

Bump `MARKETING_VERSION` by SemVer policy for that slice.
Increment `CURRENT_PROJECT_VERSION` on every upload.
Run `xcodegen generate --spec apps/ios/project.yml`.
Archive and upload again.
