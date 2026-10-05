#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/compare-source-checkers.XXXXXX")"
swift build --quiet --package-path "$repo/tools" --product check-source
swift_checker="$repo/tools/.build/debug/check-source"
failed=0

run_both() {
  local label="$1" root="$2" expected="$3"
  local node_status=0 swift_status=0
  node "$repo/tools/check-source.mjs" --root "$root" > "$work/node.out" 2>&1 || node_status=$?
  "$swift_checker" --root "$root" > "$work/swift.out" 2>&1 || swift_status=$?
  local node_line swift_line
  node_line="$label | exit $node_status | $(grep -F '[' "$work/node.out" | paste -sd ';' - || true)"
  swift_line="$label | exit $swift_status | $(grep -F '[' "$work/swift.out" | paste -sd ';' - || true)"
  echo "node:  $node_line"
  echo "swift: $swift_line"
  echo "$node_line" >> "$work/node.lines"
  echo "$swift_line" >> "$work/swift.lines"
  if ! cmp -s "$work/node.out" "$work/swift.out"; then
    echo "DIFFERENT OUTPUT for $label"
    failed=1
  fi
  if [ -n "$expected" ] && ! grep -qF "[$expected]" "$work/swift.out"; then
    echo "MISSING [$expected] for $label"
    failed=1
  fi
}

scratch=""
begin() {
  scratch="$work/$1"
  mkdir -p "$scratch"
  git init -q "$scratch"
}
put() {
  mkdir -p "$(dirname "$scratch/$1")"
  cat > "$scratch/$1"
}
violation() {
  git -C "$scratch" add -f -- .
  run_both "$1" "$scratch" "${2-$1}"
}

project() {
  put apps/ios/Enduragent.xcodeproj/project.pbxproj <<EOF
{"rootObject":"project","objects":{
"project":{"buildConfigurationList":"projectConfigs","targets":["app","phoneTests"]},
"projectConfigs":{"buildConfigurations":["projectProof"]},
"projectProof":{"name":"DebugKeychainProof","buildSettings":{"DEVELOPMENT_TEAM":"FA494ACVTF","CODE_SIGN_STYLE":"Automatic"$1}},
"app":{"productType":"com.apple.product-type.application","buildConfigurationList":"appConfigs"},
"appConfigs":{"buildConfigurations":["appProof"]},
"appProof":{"name":"DebugKeychainProof","buildSettings":{"DEVELOPMENT_TEAM":"FA494ACVTF","CODE_SIGN_STYLE":"Automatic","SWIFT_VERSION":"6.0","PRODUCT_BUNDLE_IDENTIFIER":"icu.enduragent.keychainproof","CODE_SIGN_ENTITLEMENTS":"Enduragent/KeychainProof.entitlements"}},
"phoneTests":{"productType":"com.apple.product-type.bundle.ui-testing","buildConfigurationList":"testConfigs"},
"testConfigs":{"buildConfigurations":["testProof"]},
"testProof":{"name":"DebugKeychainProof","buildSettings":{}}}}
EOF
  put apps/ios/Enduragent/KeychainProof.entitlements <<EOF
{"keychain-access-groups":["\$(AppIdentifierPrefix)icu.enduragent.$2"]}
EOF
}

coach=apps/ios/Packages/EnduragentCoach
proofs=apps/ios/EnduragentUITests
features=.agents/skills/verify-ios/features
digits="88888888"

echo "== the real tree"
run_both "real tree" "$repo" ""

echo "== one deliberate violation per rule"
begin forbidden-path
echo text | put docs/example.md
violation forbidden-path

begin unsafe-path
ln -s .. "$scratch/first"
violation unsafe-path

begin unexpected-binary
printf 'arbitrary\0binary' | put blob.bin
violation unexpected-binary

begin xcode-shared-build-settings
project '' keychainproof
violation xcode-shared-build-settings

begin keychain-proof-storage-isolation
project ',"SWIFT_VERSION":"6.0"' app
violation keychain-proof-storage-isolation

begin app-fixture-folder-ownership
echo 'let directory = NSTemporaryDirectory()' | put apps/ios/EnduragentTests/FixtureTests.swift
violation app-fixture-folder-ownership

begin fixture-launch-debug-only
echo 'let launch = FixtureLaunch.firstWeek()' | put apps/ios/Enduragent/App/AppLaunch.swift
violation fixture-launch-debug-only

begin ui-proof-shared-helpers
echo 'element.waitForExistence(timeout: 8)' | put $proofs/ExampleSteps.swift
violation ui-proof-shared-helpers

begin ui-proof-debug-scrolling
echo 'let row = TutorialHarness.named(app, "debug.records")' | put $proofs/TutorialHarness.swift
violation ui-proof-debug-scrolling

begin ui-proof-no-skips
echo 'throw XCTSkip("missing old store")' | put $proofs/ExampleSteps.swift
violation ui-proof-no-skips

begin single-secret-store
echo 'struct Duplicate: Sendable, SecretStore {}' | put apps/ios/Store.swift
violation single-secret-store

begin test-wait-deadline
echo 'while !ready { try await changed.waitUnlessCancelled() }' | put $coach/Tests/EnduragentCoachTests/WaitSupport.swift
violation test-wait-deadline

begin test-hang-guard-duration
echo 'let deadline = ContinuousClock.now + .seconds(5)' | put $coach/Tests/EnduragentCoachTests/WaitSupport.swift
violation test-hang-guard-duration

begin intervals-id
echo "let athlete = \"i$digits\"" | put apps/ios/value.swift
violation intervals-id

begin app-number-formatting
echo 'String(Int(value.rounded()))' | put apps/ios/Enduragent/Onboarding/ConnectView.swift
violation app-number-formatting

begin lint-disable
echo '// swiftlint:disable:this no_comments' | put apps/ios/Enduragent/Screen.swift
violation lint-disable

begin records-package-only
echo 'public struct Body {}' | put $coach/Sources/EnduragentCoach/Records/Body.swift
violation records-package-only

begin ledger-index-version
printf '%s\n' '#Index<StoredAthleteRecord>([\.deviceId, \.hlcWallMs, \.hlcLogical])' '@Attribute(hashModifier: "ledger-indexes-v1")' 'var deviceId: String = ""' | put $coach/Sources/EnduragentCoach/Records/StoredAthleteRecord.swift
violation ledger-index-version

begin mailbox-private-state
printf '%s\n' 'package actor ChatMailbox {' 'var runner: TurnRunner' '}' | put $coach/Sources/EnduragentCoach/Chat/ChatMailbox.swift
violation mailbox-private-state

begin activity-id
echo "{\"id\":\"$digits$digits\"}" | put activity.json
violation activity-id

begin fixture-date
echo '{"start_date_local":"2026-06-07"}' | put $coach/Tests/EnduragentCoachTests/Fixtures/intervals-activity.json
violation fixture-date

begin secret-shape
printf '%s%s\n' '-----BEGIN ' 'PRIVATE KEY-----' | put key.txt
violation secret-shape

begin public-language-prose
echo 'Your CTL is rising.' | put README.md
violation "public-language (prose)" public-language

begin public-language-swift
echo 'Text("Normalized Power")' | put apps/ios/Enduragent/Screen.swift
violation "public-language (Swift label)" public-language

begin public-language-typescript
echo 'const message = "Your CTL is rising";' | put packages/i18n/scripts/message.ts
violation "public-language (TypeScript)" public-language

begin public-language-catalog
echo '{"telegram":{"NP":"體能","status":{"working":"正在取得體能CTL資料…"}}}' | put packages/i18n/catalogs/zh-Hant.json
violation "public-language (catalog value)" public-language

begin public-language-phrasebook
echo '{"strings":{"plan.NP":{"localizations":{"sv":{"stringUnit":{"value":"TSB-utveckling"}}}}}}' | put $coach/Sources/EnduragentCoach/Resources/Phrasebook.json
violation "public-language (Phrasebook value)" public-language

begin shell-navigation-stack-owner
echo 'struct ChatView: View { var body: some View { NavigationStack(path: $model.navigation) { SettingsView() } } }' | put apps/ios/Enduragent/Chat/ChatView.swift
echo 'struct SettingsView: View { var body: some View { NavigationStack { Text(title) } } }' | put apps/ios/Enduragent/Settings/SettingsView.swift
violation shell-navigation-stack-owner

begin feature-proof-reference
echo 'final class ChatProof: XCTestCase { func testReply() {} }' | put $proofs/ChatProofs.swift
printf '# Chat\nChatProof/testReply MissingProof\n' | put $features/chat.md
violation feature-proof-reference

begin feature-proof-method
echo 'final class ChatProof: XCTestCase { func testReply() {} }' | put $proofs/ChatProofs.swift
printf '# Chat\nChatProof/testMissing\n' | put $features/chat.md
violation feature-proof-method

begin feature-proof-unmapped
echo 'final class ChatProof: XCTestCase { func testReply() {} }' | put $proofs/ChatProofs.swift
printf '# Chat\nThe conversation.\n' | put $features/chat.md
violation feature-proof-unmapped

echo "== a tree neither checker can read"
begin unreadable
printf '\377\376 not UTF-8\n' | put broken.txt
violation "file that is not UTF-8" ""

echo "== rule names in the Node checker and rules seen above"
grep -o "report(file, '[a-z-]*'" "$repo/tools/check-source.mjs" | sed "s/.*'\(.*\)'/\1/" | sort -u > "$work/node.rules"
grep -o '\[[a-z-]*\]' "$work/swift.lines" | tr -d '[]' | sort -u > "$work/swift.rules"
echo "Node checker source: $(wc -l < "$work/node.rules" | tr -d ' ') rules; reported by the Swift checker above: $(wc -l < "$work/swift.rules" | tr -d ' ') rules"
diff "$work/node.rules" "$work/swift.rules" || failed=1

echo "== test case names"
cat > "$work/names.mjs" <<'EOF'
export default async function* names(source) {
  for await (const event of source) {
    if (event.type === 'test:pass' || event.type === 'test:fail') yield `${JSON.stringify(event.data.name)}\n`;
  }
}
EOF
node --test --test-reporter="$work/names.mjs" "$repo/tools/check-source.test.mjs" | sort > "$work/node.cases"
swift test --package-path "$repo/tools" --filter SourceCheckerTests 2>&1 \
  | sed -n 's/^.* sourceCase → \(".*"\) to givesTheVerdictForATrackedTree(_:) started\.$/\1/p' | sort > "$work/swift.cases"
echo "Node cases: $(wc -l < "$work/node.cases" | tr -d ' '); Swift cases: $(wc -l < "$work/swift.cases" | tr -d ' ')"
echo "Node cases missing from Swift:"
comm -23 "$work/node.cases" "$work/swift.cases"
echo "Swift cases not in the Node file:"
comm -13 "$work/node.cases" "$work/swift.cases"
if [ -n "$(comm -23 "$work/node.cases" "$work/swift.cases")" ]; then failed=1; fi

echo "== verdict"
if diff "$work/node.lines" "$work/swift.lines" > /dev/null && [ "$failed" -eq 0 ]; then
  echo "same verdicts, same findings, every Node case present ($work)"
else
  echo "DIFFERENT ($work)"
  exit 1
fi
