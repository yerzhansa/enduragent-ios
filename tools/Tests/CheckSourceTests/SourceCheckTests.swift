import Foundation
import Testing
import ToolSupport

@testable import CheckSource

private let fixture =
	"apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures/intervals-activity.json"
private let sensitiveID = "i" + String(repeating: "8", count: 8)
private let activityID = String(repeating: "9", count: 11)

struct RejectedSource: Sendable, CustomTestStringConvertible {
	let name: String
	let file: String
	let content: String
	let rule: String

	var testDescription: String { name }
}

private let rejected = [
	RejectedSource(
		name: "intervals identifier", file: "apps/ios/value.swift", content: sensitiveID,
		rule: "intervals-id"),
	RejectedSource(
		name: "large JSON activity identifier", file: fixture,
		content: "{\"id\":\"\(activityID)\"}", rule: "activity-id"),
	RejectedSource(
		name: "large activity URL", file: "README.md", content: "/activity/" + activityID,
		rule: "activity-id"),
	RejectedSource(
		name: "current-era fixture date", file: fixture,
		content: "{\"start_date_local\":\"2026-06-07\"}", rule: "fixture-date"),
	RejectedSource(
		name: "environment file", file: ".env.production", content: "TOKEN=placeholder",
		rule: "forbidden-path"),
	RejectedSource(
		name: "local app credentials", file: "apps/ios/.dev.vars", content: "TOKEN=placeholder",
		rule: "forbidden-path"),
	RejectedSource(
		name: "build output", file: "apps/ios/.build/debug/app", content: "binary",
		rule: "forbidden-path"),
	RejectedSource(
		name: "ignored documentation", file: "docs/example.md", content: "text",
		rule: "forbidden-path"),
	RejectedSource(
		name: "private key", file: "key.txt", content: "-----BEGIN " + "PRIVATE KEY-----",
		rule: "secret-shape"),
	RejectedSource(
		name: "Swift label", file: "apps/ios/Enduragent/Screen.swift",
		content: "Text(\"Normalized Power\")", rule: "public-language"),
	RejectedSource(
		name: "public prose", file: "README.md", content: "Your CTL is rising.",
		rule: "public-language"),
	RejectedSource(
		name: "SwiftLint disable command", file: "apps/ios/Enduragent/Screen.swift",
		content: "// swiftlint:" + "disable:this no_comments", rule: "lint-disable"),
]

@Test(arguments: rejected)
func rejectsWithoutPrintingMatchedData(source: RejectedSource) throws {
	let report = try check([source.file: Data(source.content.utf8)])
	let output = (report.violations.map(\.line) + [report.summary]).joined(separator: "\n")
	#expect(!report.violations.isEmpty, "\(output)")
	#expect(output.contains("[\(source.rule)]"))
	#expect(!output.contains(sensitiveID))
	#expect(!output.contains(activityID))
}

@Test func acceptsTheAppStoreIcon() throws {
	let report = try check([
		"apps/ios/Enduragent/Assets.xcassets/AppIcon.appiconset/AppIcon.png": Data([
			137, 80, 78, 71, 0, 1, 2, 3,
		])
	])
	#expect(report.violations.isEmpty)
}

@Test func acceptsHistoricalFixturesAndTechnicalIdentifiers() throws {
	let report = try check(
		[
			fixture:
				"{\"id\":\"i1234567\",\"start_date_local\":\"1998-06-07\",\"icu_training_load\":120}",
			"apps/ios/Screen.swift": "let CTL = 1\nlet codingKey = \"NP\"\nText(\"Fitness\")",
			"NOTICE.md": "THE SOFTWARE IS PROVIDED AS IS, IF ANY.",
			"packages/i18n/catalogs/en.json":
				"{\"NP\":\"weighted average power\",\"IF\":\"Intensity\"}",
			"packages/i18n/catalogs/sv.json": "{\"legacy\":\"TSB\"}",
			"apps/ios/Resources/Phrasebook.json": "{\"legacy\":\"TSB\"}",
			"README.md": "Fitness and Load.\n```\nCTL\n```\nUse `NP` as the API field.",
		].mapValues { Data($0.utf8) })
	#expect(report.violations.isEmpty, "\(report.violations.map(\.line))")
	#expect(report.count == 7)
}

@Test func doesNotInspectUntrackedCredentials() throws {
	let report = try check([".dev.vars": Data("secret".utf8)], tracked: false)
	#expect(report.violations.isEmpty)
	#expect(report.count == 0)
}

private func check(_ files: [String: Data], tracked: Bool = true) throws -> SourceCheckReport {
	let root = FileManager.default.temporaryDirectory
		.appendingPathComponent("ios-source-check-\(UUID().uuidString)", isDirectory: true)
	try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	let report: SourceCheckReport
	do {
		report = try populateAndCheck(root: root, files: files, tracked: tracked)
	} catch {
		try FileManager.default.removeItem(at: root)
		throw error
	}
	try FileManager.default.removeItem(at: root)
	return report
}

private func populateAndCheck(
	root: URL, files: [String: Data], tracked: Bool
) throws -> SourceCheckReport {
	_ = try Shell.output("git", ["init", "-q", root.path])
	for (file, content) in files {
		let url = root.appendingPathComponent(file)
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try content.write(to: url)
	}
	if tracked {
		_ = try Shell.output("git", ["-C", root.path, "add", "-f", "."])
	}
	return try SourceCheck().run(root: root.path)
}
