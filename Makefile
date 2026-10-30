ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
AT_ROOT := cd "$(ROOT)" &&
TOOL := swift run --quiet --package-path tools
COACH := apps/ios/Packages/EnduragentCoach
CATALOG_OUTPUTS := $(COACH)/Sources/EnduragentCoach/I18n $(COACH)/Sources/EnduragentCoach/Resources
SWIFT_SOURCES := git ls-files -z -- '*.swift' ':!*.generated.swift'
SWIFT_FORMAT := xargs -0 swift format
FORMAT_OPTIONS := --parallel --configuration .swift-format
APP_PROJECT := apps/ios/Enduragent.xcodeproj
DERIVED_DATA ?= DerivedData
ONLY ?= EnduragentTests
PLAN_FIXTURES := $(COACH)/Tests/EnduragentCoachTests/Fixtures/plan
NPM_FIXTURES := node tools/npm-fixtures/run.mjs --npm "$(NPM)" --out $(PLAN_FIXTURES)
LIVE_LOGS ?= $(HOME)/Library/Logs/enduragent-m3/LIVE
LIVE_CHECK := env -u OPENROUTER_API_KEY -u INTERVALS_API_KEY ENDURAGENT_LIVE_LOGS="$(LIVE_LOGS)"
FEEDBACK_LOGS := $(HOME)/Library/Logs/enduragent-m6/LIVE
DESKTOP_SPECIFICATION = $(abspath $(DESKTOP))/docs/initiatives/npm-telegram-feature-inventory/ios-parity-build/specification.json
DESKTOP_DECISION = $(abspath $(DESKTOP))/docs/adr/0085-ios-closes-parity-with-a-diagnostics-file-note-only-feedback-and-apple-owned-updates.md
REQUIRE_DESKTOP = test -n "$(DESKTOP)" || { echo "make $@ needs DESKTOP=<path to the desktop checkout>" >&2; exit 2; }
IPHONE_SIMULATOR := xcodebuild -project $(APP_PROJECT) -scheme Enduragent -showdestinations | awk '/Available destinations for/ { available = 1; next } /Ineligible destinations for/ { available = 0 } available && /platform:iOS Simulator/ && /name:iPhone/ { sub(/^.*id:/, ""); sub(/,.*/, ""); print; exit }'

.PHONY: project generate-catalogs check-catalogs check-source check-coverage closeout check-closeout-final write-retained check-retained lint-swift format-swift check-format test-tools test-swift test-app test-keychain plan-fixtures plan-fixtures-check live-reads live-calendar live-coach live-plan live-seed live-unseed live-feedback-note

project:
	$(AT_ROOT) xcodegen generate --spec apps/ios/project.yml

generate-catalogs:
	$(AT_ROOT) $(TOOL) generate-catalogs

check-catalogs: generate-catalogs
	$(AT_ROOT) git diff --exit-code -- $(CATALOG_OUTPUTS)

check-source:
	$(AT_ROOT) $(TOOL) check-source

check-coverage:
	$(AT_ROOT) $(TOOL) check-coverage coverage/*.json

closeout:
	$(AT_ROOT) $(TOOL) check-coverage --write-closeout coverage/milestone-6.json

check-closeout-final: check-retained
	$(AT_ROOT) $(TOOL) check-coverage --require-final coverage/*.json

write-retained:
	@$(REQUIRE_DESKTOP)
	$(AT_ROOT) $(TOOL) check-coverage --write-retained "$(DESKTOP_SPECIFICATION)" "$(DESKTOP_DECISION)"

check-retained:
	@$(REQUIRE_DESKTOP)
	$(AT_ROOT) $(TOOL) check-coverage --retained-drift "$(DESKTOP_SPECIFICATION)" "$(DESKTOP_DECISION)"

lint-swift:
	$(AT_ROOT) swiftlint lint --strict --quiet $(ARGS)

format-swift:
	$(AT_ROOT) $(SWIFT_SOURCES) | $(SWIFT_FORMAT) format --in-place $(FORMAT_OPTIONS)

check-format:
	$(AT_ROOT) $(SWIFT_SOURCES) | $(SWIFT_FORMAT) lint --strict $(FORMAT_OPTIONS)

test-tools:
	$(AT_ROOT) swift test --package-path tools $(ARGS)

test-swift:
	$(AT_ROOT) env -u OPENROUTER_API_KEY -u INTERVALS_API_KEY -u ENDURAGENT_LIVE swift test --package-path $(COACH) $(ARGS)

test-app: project
	$(AT_ROOT) destination="$$($(IPHONE_SIMULATOR))" && test -n "$$destination" && xcodebuild test -project $(APP_PROJECT) -scheme Enduragent -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,arch=arm64,id=$$destination" -derivedDataPath $(DERIVED_DATA) -only-testing:$(ONLY) CODE_SIGNING_ALLOWED=NO

test-keychain: project
	$(AT_ROOT) destination="$(or $(SIMULATOR),$$($(IPHONE_SIMULATOR)))" && test -n "$$destination" && TEST_RUNNER_ENDURAGENT_KEYCHAIN_TESTS=1 xcodebuild test -project $(APP_PROJECT) -scheme Enduragent -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,arch=arm64,id=$$destination" -derivedDataPath $(DERIVED_DATA) -only-testing:EnduragentTests/KeychainErasureTests -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=

plan-fixtures:
	$(AT_ROOT) $(NPM_FIXTURES)

plan-fixtures-check:
	$(AT_ROOT) $(NPM_FIXTURES) --check

live-reads:
	$(AT_ROOT) $(LIVE_CHECK) ENDURAGENT_LIVE=reads swift test --package-path $(COACH) --filter EnduragentCoachLiveChecks.LiveReadsCheck $(ARGS)

live-calendar:
	$(AT_ROOT) $(LIVE_CHECK) ENDURAGENT_LIVE=calendar swift test --package-path $(COACH) --filter EnduragentCoachLiveChecks.LiveCalendarCheck $(ARGS)

live-coach:
	$(AT_ROOT) $(LIVE_CHECK) ENDURAGENT_LIVE=coach swift test --package-path $(COACH) --filter EnduragentCoachLiveChecks.LiveCoachCheck $(ARGS)

live-plan:
	$(AT_ROOT) $(LIVE_CHECK) ENDURAGENT_LIVE=plan swift test --package-path $(COACH) --filter EnduragentCoachLiveChecks.LivePlanCheck $(ARGS)

live-seed:
	$(AT_ROOT) $(LIVE_CHECK) ENDURAGENT_LIVE=seed swift test --package-path $(COACH) --filter EnduragentCoachLiveChecks.LiveSeedCheck $(ARGS)

live-unseed:
	$(AT_ROOT) $(LIVE_CHECK) ENDURAGENT_LIVE=unseed swift test --package-path $(COACH) --filter EnduragentCoachLiveChecks.LiveSeedCheck $(ARGS)

live-feedback-note:
	$(AT_ROOT) env -u OPENROUTER_API_KEY -u INTERVALS_API_KEY ENDURAGENT_LIVE_LOGS="$(FEEDBACK_LOGS)" ENDURAGENT_LIVE=feedback swift test --package-path $(COACH) --filter EnduragentCoachLiveChecks.LiveFeedbackNote $(ARGS)
