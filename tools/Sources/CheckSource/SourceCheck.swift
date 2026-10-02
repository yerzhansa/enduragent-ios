import Foundation
import ToolSupport

struct Violation: Equatable {
	let file: String
	let rule: String

	var line: String { "\(String(reflecting: file)) [\(rule)]" }
}

struct SourceCheckReport {
	let count: Int
	let violations: [Violation]

	var summary: String {
		"check-source: \(count) tracked files; \(violations.count) violations."
	}
}

struct SourceCheckFailure: Error, CustomStringConvertible {
	let description: String
}

struct SourceCheck {
	private let forbiddenPath: Pattern
	private let language: Pattern
	private let fixture: Pattern
	private let appIcon: Pattern
	private let intervalsID: Pattern
	private let lintCommand: Pattern
	private let activityID: Pattern
	private let datedYear: Pattern
	private let secretShape: Pattern
	private let markdownCode: Pattern
	private let swiftCopy: Pattern

	init() throws {
		forbiddenPath = try Pattern(
			#"(?:^|/)(?:docs|\.build|build|dist|out|DerivedData|\.wrangler|\.swiftpm|xcuserdata|\.idea)(?:/|$)|(?:^|/)(?:\.env(?:\.[^/]*)?|\.dev\.vars(?:\.[^/]*)?|credentials(?:\.[^/]*)?|[^/]+\.(?:p12|p8|mobileprovision|keychain|keychain-db|ipa|xcarchive))$"#,
			caseInsensitive: true)
		language = try Pattern(
			#"\b(?:CTL|ATL|TSB|TSS|IF|NP|Normalized\s+Power|[Nn]orm\s+[Pp]ower)\b"#)
		fixture = try Pattern(#"^apps/ios/.*/Tests/.*/Fixtures/"#)
		appIcon = try Pattern(
			#"^apps/ios/Enduragent/Assets\.xcassets/AppIcon\.appiconset/AppIcon\.png$"#)
		intervalsID = try Pattern(#"\bi\d{8,9}\b"#)
		lintCommand = try Pattern(#"swiftlint:(?:disable|enable)"#)
		activityID = try Pattern(
			#"(?:["'](?:id|activity_?id)["']\s*:\s*["']?\d{9,}\b|/activit(?:y|ies)/\d{9,}\b|\bactivity_?[Ii][Dd]\s*[:=]\s*["']?\d{9,}\b)"#
		)
		datedYear = try Pattern(#"\b(\d{4})-\d{2}-\d{2}\b"#)
		secretShape = try Pattern(
			#"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-or-v1-[a-f0-9]{32,}|AKIA[A-Z0-9]{16})\b"#
		)
		markdownCode = try Pattern(#"```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`]*`"#)
		swiftCopy = try Pattern(
			#"\b(?:Text|Label|Button|Section|navigationTitle|alert|confirmationDialog|String\(localized:)\s*\(?(?:\s*)"((?:\\.|[^"\\])*)""#
		)
	}

	func run(root requested: String) throws -> SourceCheckReport {
		let root = try realPath(requested)
		let listing = try Shell.output("git", ["-C", root, "ls-files", "-z"])
		let files = listing.split(separator: "\0").map(String.init)
		var violations: [Violation] = []
		for file in files {
			violations.append(contentsOf: try check(file, root: root))
		}
		return SourceCheckReport(count: files.count, violations: violations)
	}

	private func check(_ file: String, root: String) throws -> [Violation] {
		if forbiddenPath.matches(file) {
			return [Violation(file: file, rule: "forbidden-path")]
		}
		let path = "\(root)/\(file)"
		if try isSymbolicLink(path) || !(try realPath(path)).hasPrefix("\(root)/") {
			return [Violation(file: file, rule: "unsafe-path")]
		}
		let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
		if bytes.contains(0) {
			return appIcon.matches(file) ? [] : [Violation(file: file, rule: "unexpected-binary")]
		}
		guard let text = String(validating: bytes, as: UTF8.self) else {
			throw SourceCheckFailure(description: "\(file) is not UTF-8")
		}
		return contentRules(file: file, text: text).map { Violation(file: file, rule: $0) }
	}

	private func contentRules(file: String, text: String) -> [String] {
		var rules: [String] = []
		if intervalsID.matches(text) { rules.append("intervals-id") }
		if file.hasSuffix(".swift") && lintCommand.matches(text) { rules.append("lint-disable") }
		if activityID.matches(text) { rules.append("activity-id") }
		if fixture.matches(file)
			&& datedYear.captures(in: text).contains(where: { (Int($0) ?? 0) >= 2015 })
		{
			rules.append("fixture-date")
		}
		if secretShape.matches(text) { rules.append("secret-shape") }
		if publicText(file: file, text: text).contains(where: language.matches) {
			rules.append("public-language")
		}
		return rules
	}

	private func publicText(file: String, text: String) -> [String] {
		if file.hasSuffix(".md") && (file as NSString).lastPathComponent != "NOTICE.md" {
			return [markdownCode.removing(from: text)]
		}
		if file.hasSuffix(".swift") && !file.contains("/Tests/") {
			return swiftCopy.captures(in: text)
		}
		return []
	}

	private func realPath(_ path: String) throws -> String {
		guard let resolved = realpath(path, nil) else {
			throw SourceCheckFailure(description: "cannot resolve \(path)")
		}
		let result = String(cString: resolved)
		free(resolved)
		return result
	}

	private func isSymbolicLink(_ path: String) throws -> Bool {
		let attributes = try FileManager.default.attributesOfItem(atPath: path)
		return attributes[.type] as? FileAttributeType == .typeSymbolicLink
	}
}

private struct Pattern {
	let expression: NSRegularExpression

	init(_ pattern: String, caseInsensitive: Bool = false) throws {
		expression = try NSRegularExpression(
			pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
	}

	func matches(_ text: String) -> Bool {
		expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
	}

	func captures(in text: String) -> [String] {
		expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
			Range($0.range(at: 1), in: text).map { String(text[$0]) }
		}
	}

	func removing(from text: String) -> String {
		expression.stringByReplacingMatches(
			in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
	}
}
