# iOS release

This is the iPhone release path, from a TestFlight upload to an App Store release. The Railway image runbook does not apply.

## Identity

Read `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from `apps/ios/project.yml`. Do not hardcode the next version in a script.
`MARKETING_VERSION` must equal the version name in App Store Connect, because App Store Connect matches the build's `CFBundleShortVersionString` to it.
Every upload uses a `CURRENT_PROJECT_VERSION` higher than every build already uploaded for the app. Apple requires only a unique build number per version; this repository never reuses or lowers one.
Bundle id is `icu.enduragent.app`.
Team is `FA494ACVTF`.
Display name is `Enduragent`.

`CREDITS_WORKER_BASE` is a build setting. Every build uses `https://credits.enduragent.icu`, the production Credits worker. It is `apps/credits-worker` in `yerzhansa/enduragent-backend`, deployed with env `production`.
`OPENROUTER_MODEL` is a build setting. Read it from `apps/ios/project.yml`.

## Lane

Uploads are from the operator Mac with Xcode automatic signing.
Do not merge a GitHub Actions upload workflow until the operator approves that specific workflow PR.

## CloudKit schema to Production

Do this before every archive whose build changes the record types, and before the first TestFlight upload.

1. Open the CloudKit Console with the developer-only Apple ID and pick the container `iCloud.icu.enduragent.ios`.
2. Open the Development schema and choose Deploy Schema Changes.
3. Check that the listed record types and fields are the ones the build reads and writes, then deploy them to Production.

If the Production deploy fails, stop and report. Never upload a build against a Development-only schema.

## Closeout gate

Run this from the repository root, on the commit the build is archived from:

```sh
make check-closeout-final DESKTOP=<path to the desktop checkout>
```

It passes only when `coverage/closeout/evidence.json` has stage `final`, no coverage table has an open row, and every phone step a closeout row cites is `pass` in `coverage/closeout/sitting.json`.

Run it before the archive step. Archive only from a clean tree: `git status --porcelain` must print nothing. Then tag the commit with the version and build from `apps/ios/project.yml`, and push the tag:

```sh
git tag ios-<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>
git push origin ios-<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>
```

A build whose commit fails the gate may go to TestFlight, for example to rerun sitting steps, but it must never be submitted for App Review. Before you submit a build for App Review, run the gate again on its tag, as "Submit for App Review" says, and submit only if it passes. A build with no tag is never submitted.

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

The app record is named `Enduragent`, with bundle id `icu.enduragent.app`.
Use the developer-only Apple ID.

Upload with an App Store Connect API key. Put `AuthKey_<KEYID>.p8` in `~/.appstoreconnect/private_keys/`. Never commit the key, and never print it.

```sh
xcrun altool --upload-app --type ios \
  --file /tmp/Enduragent-export/Enduragent.ipa \
  --apiKey KEYID \
  --apiIssuer ISSUER
```

Wait until the build's processing state is `VALID` in the App Store Connect API, or the build no longer shows Processing in TestFlight.

`ITSAppUsesNonExemptEncryption` is `false` in `project.yml`, so App Store Connect asks no export compliance question for the build.

## TestFlight

TestFlight group `Athletes` holds the testers. The operator iPhone is the first tester.

To roll back a TestFlight build, expire it in TestFlight. Do not delete the app record.

## App Store

An App Store build is a TestFlight build whose tag passes the closeout gate. Steps marked **Operator** are done by the operator in App Store Connect. An agent may do the other App Store Connect steps through the App Store Connect API only after the operator approves that step.

### Prepare the build

1. Set `MARKETING_VERSION` to the App Store Connect version name, and set `CURRENT_PROJECT_VERSION` above every uploaded build. Commit the change.
2. Check that `CREDITS_WORKER_BASE` in `apps/ios/project.yml` is `https://credits.enduragent.icu`. If it is not, stop.
3. Do "CloudKit schema to Production", "Closeout gate", "Archive on the operator Mac" and the upload in "App Store Connect", in that order.
4. Install the build from TestFlight on the operator iPhone. Reach a coach reply on each access method that the review notes describe.

### Fill the version page

1. Under Build, select the tagged build.
2. Under App Information, enter the name, subtitle, primary category Health & Fitness, secondary category Sports and the content rights answer.
3. Under the version, enter the promotional text, description, keywords, support URL, marketing URL and copyright. The support page must be live first.
4. Set Version Release to "Manually release this version", so the release is a separate step.
5. Upload screenshots for iPhone 6.9" (1320 × 2868) and iPhone 6.3" (1206 × 2622), portrait, PNG without an alpha channel. Capture them with the `verify-ios` skill in two runs, one created with `ENDURAGENT_SIM_DEVICE="iPhone 17 Pro Max" sim create <slug>` and one with `ENDURAGENT_SIM_DEVICE="iPhone 17 Pro" sim create <slug>`. The skill's default simulator is a size App Store Connect does not accept. `sim create` sets the status bar. Check each file with `sips -g pixelWidth -g pixelHeight -g hasAlpha <file>`. No screenshot may show a debug control, a fixture label, a key, or the About screen, which shows the fixture version in fixture mode.
6. **Operator.** Under App Privacy, next to Privacy Policy, choose Edit and enter the privacy policy URL. The page must be live first. Then answer the App Privacy questionnaire from `release/app-privacy.json`: tracking No, and for each listed type the purpose and the linked value the file gives. Untick every type the file does not list. Publish the label. The file lists the same collected data types as `apps/ios/Enduragent/PrivacyInfo.xcprivacy`, and `make check-source` keeps the two equal. The App Store Connect API has no endpoint for this.
7. Answer the age rating questionnaire.
8. **Operator.** Under Pricing and Availability, set the price and the countries and regions. Declare the Digital Services Act trader status under Business > Agreements > Compliance, then check it for this app under App Information > App Store Regulations and Permits. Apple asks for it even if the app is not distributed in the EU. A trader's address, phone number and email appear on the EU product page.
9. Attach no in-app purchase. The app sells none.
10. **Operator.** Under App Review Information, enter the notes, the demo sign-in and the contact fields. Credentials and contact details are typed by the operator only.

### Submit for App Review

1. Make a worktree at the build's tag with `git worktree add .worktrees/ios-<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION> ios-<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>`. In it, run `make check-closeout-final DESKTOP=<path to the desktop checkout>`. Submit only if it passes.
2. **Operator.** Check that no section of the version shows a warning. Choose Add for Review, then Submit for Review.

### Release

1. After approval, the version waits in Pending Developer Release.
2. **Operator.** Choose Release This Version.

### App Store rollback

1. Before release: on the version page, choose "remove this version from review", then Remove. The version becomes Developer Rejected. Upload a fixed build with a higher `CURRENT_PROJECT_VERSION`, select it, and submit again.
2. After release: submit a fixed version. To stop new downloads, remove the app from sale in Pricing and Availability. Do not delete the app record.

## Later builds

Bump `MARKETING_VERSION` by SemVer policy for that slice, and create the matching version in App Store Connect.
Increment `CURRENT_PROJECT_VERSION` on every upload.
Run `xcodegen generate --spec apps/ios/project.yml`.
Archive and upload again.
