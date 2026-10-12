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
IPHONE_SIMULATOR := xcodebuild -project $(APP_PROJECT) -scheme Enduragent -showdestinations | awk '/Available destinations for/ { available = 1; next } /Ineligible destinations for/ { available = 0 } available && /platform:iOS Simulator/ && /name:iPhone/ { sub(/^.*id:/, ""); sub(/,.*/, ""); print; exit }'

.PHONY: project generate-catalogs check-catalogs check-source lint-swift format-swift check-format test-tools test-swift test-app

project:
	$(AT_ROOT) xcodegen generate --spec apps/ios/project.yml

generate-catalogs:
	$(AT_ROOT) $(TOOL) generate-catalogs

check-catalogs: generate-catalogs
	$(AT_ROOT) git diff --exit-code -- $(CATALOG_OUTPUTS)

check-source:
	$(AT_ROOT) $(TOOL) check-source

lint-swift:
	$(AT_ROOT) swiftlint lint --strict --quiet $(ARGS)

format-swift:
	$(AT_ROOT) $(SWIFT_SOURCES) | $(SWIFT_FORMAT) format --in-place $(FORMAT_OPTIONS)

check-format:
	$(AT_ROOT) $(SWIFT_SOURCES) | $(SWIFT_FORMAT) lint --strict $(FORMAT_OPTIONS)

test-tools:
	$(AT_ROOT) swift test --package-path tools $(ARGS)

test-swift:
	$(AT_ROOT) env -u OPENROUTER_API_KEY -u INTERVALS_API_KEY swift test --package-path $(COACH) $(ARGS)

test-app: project
	$(AT_ROOT) destination="$$($(IPHONE_SIMULATOR))" && test -n "$$destination" && xcodebuild test -project $(APP_PROJECT) -scheme Enduragent -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,arch=arm64,id=$$destination" -derivedDataPath $(DERIVED_DATA) -only-testing:$(ONLY) CODE_SIGNING_ALLOWED=NO
