CATALOG_OUTPUTS := apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/I18n apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Resources
SWIFT_SOURCES := git ls-files -z -- '*.swift' ':!*.generated.swift'

.PHONY: generate-catalogs check-catalogs check-source lint-swift format-swift check-format test-swift

generate-catalogs:
	swift run --quiet --package-path tools generate-catalogs

check-catalogs: generate-catalogs
	git diff --exit-code -- $(CATALOG_OUTPUTS)

check-source:
	swift test --package-path tools
	swift run --quiet --package-path tools check-source

lint-swift:
	swiftlint lint --strict --quiet

format-swift:
	$(SWIFT_SOURCES) | xargs -0 swift format format --in-place --parallel --configuration .swift-format

check-format:
	$(SWIFT_SOURCES) | xargs -0 swift format lint --strict --parallel --configuration .swift-format

test-swift:
	env -u OPENROUTER_API_KEY -u INTERVALS_API_KEY swift test --package-path apps/ios/Packages/EnduragentCoach
