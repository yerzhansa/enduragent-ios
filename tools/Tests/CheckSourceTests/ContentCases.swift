extension SourceCases {
	static let fixture =
		"\(coachTests)/Fixtures/intervals-activity.json"
	static let sensitiveID = "i" + String(repeating: "8", count: 8)
	static let activityID = String(repeating: "9", count: 11)
	static let phrasebook =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Resources/Phrasebook.json"
	static let screen = "apps/ios/Enduragent/Screen.swift"

	private static func rejectsWithoutData(
		_ name: String, _ file: String, _ value: String, _ rule: String
	) -> SourceCase {
		.rejects(
			"rejects \(name) without printing matched data", [file: value], finding: rule,
			hidden: [sensitiveID, activityID])
	}

	private static func rejectsSentence(
		_ name: String, _ file: String, _ content: String, key: String
	) -> SourceCase {
		.rejects(
			"rejects a training abbreviation in a sentence of \(name), naming the file and key",
			[file: content], finding: "public-language",
			findingLines: ["\"\(file)\" [public-language] \"\(key)\""])
	}

	static let contentRules: [SourceCase] = [
		rejectsWithoutData(
			"rounded app number", "apps/ios/Enduragent/Onboarding/ConnectView.swift",
			"String(Int(value.rounded()))", "app-number-formatting"),
		rejectsWithoutData(
			"intervals identifier", "apps/ios/value.swift", sensitiveID, "intervals-id"),
		rejectsWithoutData(
			"large JSON activity identifier", fixture, "{\"id\":\"\(activityID)\"}", "activity-id"),
		rejectsWithoutData(
			"large activity URL", "README.md", "/activity/" + activityID, "activity-id"),
		rejectsWithoutData(
			"current-era fixture date", fixture, #"{"start_date_local":"2026-06-07"}"#,
			"fixture-date"),
		rejectsWithoutData(
			"environment file", ".env.production", "TOKEN=placeholder", "forbidden-path"),
		rejectsWithoutData(
			"local app credentials", "apps/ios/.dev.vars", "TOKEN=placeholder", "forbidden-path"),
		rejectsWithoutData("build output", "apps/ios/.build/debug/app", "binary", "forbidden-path"),
		rejectsWithoutData("ignored documentation", "docs/example.md", "text", "forbidden-path"),
		rejectsWithoutData(
			"private key", "key.txt", "-----BEGIN " + "PRIVATE KEY-----", "secret-shape"),
		rejectsWithoutData(
			"app TypeScript public wording", "packages/i18n/scripts/message.ts",
			#"const message = "Your CTL is rising";"#, "public-language"),
		rejectsWithoutData("Swift label", screen, #"Text("Normalized Power")"#, "public-language"),
		rejectsWithoutData("public prose", "README.md", "Your CTL is rising.", "public-language"),
		rejectsWithoutData(
			"SwiftLint disable command", screen, "// swiftlint:" + "disable:this no_comments",
			"lint-disable"),
		.accepts(
			"accepts the App Store 1024 icon",
			binaries: [
				"apps/ios/Enduragent/Assets.xcassets/AppIcon.appiconset/AppIcon.png": [
					137, 80, 78, 71, 0, 1, 2, 3,
				]
			]),
		.accepts(
			"accepts historical fixtures and technical identifiers",
			[
				fixture:
					#"{"id":"i1234567","start_date_local":"1998-06-07","icu_training_load":120}"#,
				"apps/ios/Screen.swift": "let CTL = 1\nlet codingKey = \"NP\"\nText(\"Fitness\")",
				"NOTICE.md": "THE SOFTWARE IS PROVIDED AS IS, IF ANY.",
				"packages/i18n/catalogs/en.json":
					#"{"NP":"weighted average power","IF":"Intensity"}"#,
				"packages/i18n/catalogs/sv.json": #"{"TSB":{"IF":"Form"}}"#,
				phrasebook:
					#"{"strings":{"plan.NP":{"localizations":{"sv":{"stringUnit":{"value":"Form"}}}}}}"#,
				"README.md": "Fitness and Load.\n```\nCTL\n```\nUse `NP` as the API field.",
			]),
		rejectsSentence(
			"a translated catalog", "packages/i18n/catalogs/zh-Hant.json",
			#"{"telegram":{"NP":"體能","status":{"working":"正在取得體能（CTL）資料…"}}}"#,
			key: "telegram.status.working"),
		rejectsSentence(
			"the bundled Phrasebook", phrasebook,
			#"{"strings":{"plan.NP":{"localizations":{"en":{"stringUnit":{"value":"Power"}},"#
				+ #""sv":{"stringUnit":{"value":"TSB-utveckling"}}}}}}"#,
			key: "strings.plan.NP.localizations.sv.stringUnit.value"),
		.accepts(
			"does not inspect untracked credentials", [".dev.vars": "secret"], tracked: .nothing),
	]

	static let appLaunch = "apps/ios/Enduragent/App/AppLaunch.swift"
	static let appExample = "apps/ios/Enduragent/App/Example.swift"

	static let fixtureLaunch: [SourceCase] =
		[
			"let launch = FixtureLaunch.firstWeek()",
			"#if DEBUG\nlet debug = true\n#else\nlet launch = FixtureLaunch.firstWeek()\n#endif",
			"#if DEBUG\nlet debug = true\n#endif\nlet launch = FixtureLaunch.firstWeek()",
			"#if DEBUG || os(iOS)\nlet launch = FixtureLaunch.firstWeek()\n#endif",
		].map { source in
			.rejects(
				"rejects FixtureLaunch outside DEBUG: \(source)", [appLaunch: source],
				finding: "[fixture-launch-debug-only]")
		}
		+ [
			.accepts(
				"accepts FixtureLaunch in a nested DEBUG guard",
				[
					appLaunch:
						"import Foundation\n#if DEBUG\n#if os(iOS)\nlet launch = FixtureLaunch.firstWeek()\n"
						+ "#else\nlet launch = FixtureLaunch.firstWeek()\n#endif\n#endif\nlet live = true"
				]),
			.accepts(
				"accepts checked app conversions and string parsing",
				[appExample: "let rounded = Int(exactly: value.rounded())\nlet parsed = Int(raw)"]),
			.rejects(
				"rejects the fixtures import outside DEBUG",
				[appExample: "import EnduragentCoachFixtures"], finding: "fixture-launch-debug-only"
			),
		]

	static let recordSource =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Records/Body.swift"

	static let recordAccess: [SourceCase] =
		[
			"public struct Body {}", "public enum Body { case sample }",
			"public\nextension Body {}",
			"public private(set) var value: Int", "open class Body {}",
			"@_spi(Testing) public struct Body {}", "@_spi(Testing) package struct Body {}",
		].map { declaration in
			.rejects(
				"rejects record access declaration \(declaration)", [recordSource: declaration],
				finding: "[records-package-only]")
		}
		+ [
			.accepts(
				"accepts package and internal records and public handles outside Records",
				[
					recordSource:
						"package struct Body { package var value: Int }\nstruct InternalBody {}",
					"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/CoachPorts.swift":
						"public struct RecordStore {}",
					"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Diagnostics/RecordSyncProbe.swift":
						"#if DEBUG\npublic struct RecordSyncProbe {}\n#endif",
				])
		]

	static let store = "Secret" + "Store"

	static let secretStores: [SourceCase] =
		[
			"final class Duplicate: \(store), @unchecked Sendable {}",
			"struct Duplicate: Sendable, \(store) {}",
			"extension Duplicate: \(store) {}",
			"extension Outer.Inner: \(store) {}",
			"struct Duplicate<S: Sendable>: \(store) where S: Equatable {}",
			"struct Duplicate<S: Collection>: \(store) where S.Element: \(store) {}",
		].map { declaration in
			.rejects(
				"rejects a second secret store: \(declaration)",
				["apps/ios/Store.swift": declaration],
				finding: "single-secret-store")
		}
		+ [
			.accepts(
				"accepts the real secret store and fixture backings",
				[
					"apps/ios/Store.swift": "struct ICloudKeychainStore: \(store) {}",
					"apps/ios/Backing.swift":
						"final class FixtureSecretStoreBacking: SecretStoreBacking {}",
				])
		]
		+ [
			"struct Box<S: \(store)> {}",
			"struct Box<S> where S: \(store) {}",
			"struct Box<S: \(store)>: Sendable {}",
			"struct Box<S>: Sendable where S: \(store) {}",
			"extension Box: Equatable where S: \(store) {}",
			"struct Box<S: Collection<\(store)>>: Sendable {}",
		].map { declaration in
			.accepts(
				"accepts a secret store constraint: \(declaration)",
				["apps/ios/Box.swift": declaration])
		}

	static let proofFile = "apps/ios/EnduragentUITests/ChatProofs.swift"
	static let featureDirectory = ".agents/skills/verify-ios/features"
	static let featureFile = "\(featureDirectory)/chat.md"
	static let chatProof = "final class ChatProof: XCTestCase { func testReply() {} }"
	static let stopProof = "final class StopProof: XCTestCase { func testStop() {} }"

	private static func feature(_ references: String) -> String {
		"# Chat\n\(references)\n"
	}

	static let featureProofs: [SourceCase] = [
		.rejects(
			"rejects unmapped proof",
			[proofFile: "\(chatProof)\n\(stopProof)", featureFile: feature("ChatProof/testReply")],
			finding: "[feature-proof-unmapped]"),
		.rejects(
			"rejects README-only mapping",
			[
				proofFile: chatProof, "\(featureDirectory)/README.md": "ChatProof/testReply",
				featureFile: feature("The conversation."),
			], finding: "[feature-proof-unmapped]"),
		.rejects(
			"rejects unknown proof reference",
			[proofFile: chatProof, featureFile: feature("ChatProof/testReply MissingProof")],
			finding: "[feature-proof-reference]"),
		.rejects(
			"rejects unknown README probe reference",
			[
				proofFile: chatProof, "\(featureDirectory)/README.md": "MissingProbe",
				featureFile: feature("ChatProof/testReply"),
			], finding: "[feature-proof-reference]"),
		.rejects(
			"rejects missing selected method",
			[proofFile: chatProof, featureFile: feature("ChatProof/testMissing")],
			finding: "[feature-proof-method]"),
		.rejects(
			"rejects method in another proof class",
			[
				proofFile: "\(chatProof)\n\(stopProof)",
				featureFile: feature("ChatProof/testStop StopProof"),
			], finding: "[feature-proof-method]"),
		.accepts(
			"accepts proofs and probes mapped across feature files with valid selectors",
			[
				proofFile: "\(chatProof)\n\(stopProof)",
				"apps/ios/EnduragentUITests/LaunchProbes.swift":
					"final class LaunchProbe: XCTestCase { func testLaunch() {} }",
				featureFile:
					feature("ChatProof/testReply StopProof").replacingOccurrences(
						of: "\n", with: "\r\n"),
				"\(featureDirectory)/launch.md": feature("LaunchProbe/testLaunch"),
				"\(featureDirectory)/README.md":
					"# Proof map\nChatProof StopProof/testStop LaunchProbe",
			]),
	]
}
