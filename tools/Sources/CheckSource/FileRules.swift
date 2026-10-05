import Foundation
import ToolSupport

extension SourceChecker {
	static let language =
		#"\b(?:CTL|ATL|TSB|TSS|IF|NP|Normalized\s+Power|[Nn]orm\s+[Pp]ower)\b"#
	static let sentenceFile =
		#"^(?:packages\/i18n\/catalogs\/[^/]+\.json|apps\/ios\/Packages\/EnduragentCoach"#
		+ #"\/Sources\/EnduragentCoach\/Resources\/Phrasebook\.json)$"#
	static let testSource =
		#"^apps\/ios\/(?:Packages\/[^/]+\/Tests\/|Enduragent(?:UI|Phone)?Tests\/).*\.swift$"#
	static let appTestSource = #"^apps\/ios\/EnduragentTests\/.*\.swift$"#
	static let waitSource =
		#"^apps\/ios\/(?:Packages\/EnduragentCoach\/Tests\/|EnduragentTests\/).*\.swift$"#
	static let hangGuardSource =
		#"^apps\/ios\/(?:Packages\/EnduragentCoach\/(?:Tests\/|Sources\/EnduragentCoachFixtures\/)"#
		+ #"|EnduragentTests\/).*\.swift$"#
	static let recordSource =
		#"^apps\/ios\/Packages\/EnduragentCoach\/Sources\/EnduragentCoach\/Records\/.*\.swift$"#
	static let recordModel =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Records/StoredAthleteRecord.swift"
	static let mailbox =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift"
	static let sharedProofHelpers =
		#"\.launchArguments\s*(?:=|\+=)|\.waitFor(?:Non)?Existence\s*\(|\bXCTWaiter\.wait\s*\("#
		+ #"|\btimeout\s*:"#
	static let debugRowQuery =
		#"\bnamed\s*\(\s*\w+\s*,\s*"(?:fixture\.(?:expire|historyHead|requestCount"#
		+ #"|modelRequestCount)|debug\.(?:records|leases))""#
	static let appNumberFormatting =
		#"\bInt\s*\((?!\s*exactly:)\s*(?:[^;\n]*\.rounded\s*\(|(?:floor|ceil)\s*\()"#
	static let activityID =
		#"(?:["'](?:id|activity_?id)["']\s*:\s*["']?\d{9,}\b|\/activit(?:y|ies)\/\d{9,}\b"#
		+ #"|\bactivity_?[Ii][Dd]\s*[:=]\s*["']?\d{9,}\b)"#
	static let secretShape =
		#"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\b(?:gh[pousr]_[A-Za-z0-9]{30,}"#
		+ #"|github_pat_[A-Za-z0-9_]{30,}|sk-or-v1-[a-f0-9]{32,}|AKIA[A-Z0-9]{16})\b"#
	static let swiftCopy =
		#"\b(?:Text|Label|Button|Section|navigationTitle|alert|confirmationDialog"#
		+ #"|String\(localized:)\s*\(?(?:\s*)"((?:\\.|[^"\\])*)""#

	func checkTestRules(_ source: SourceFile) throws {
		let file = source.file
		let text = source.text
		let isProof = try patterns.test(Self.proofFile, file)
		let usesTemporaryFolder =
			try patterns.test(Self.testSource, file)
			&& patterns.test(#"\b(?:temporaryDirectory|NSTemporaryDirectory)\b|\/tmp\/"#, text)
		let bypassesFixtureOwner =
			try patterns.test(Self.appTestSource, file)
			&& (patterns.test(#"\bremoveItem\s*\("#, text)
				|| (!file.hasSameUnits(as: "apps/ios/EnduragentTests/FixtureTestScope.swift")
					&& patterns.test(#"\bAppServices\s*\.\s*fixture\s*\("#, text)))
		if usesTemporaryFolder || bypassesFixtureOwner {
			try findings.report(file, "app-fixture-folder-ownership")
		}
		if try patterns.test(Self.appSource, file)
			&& hasReleaseReference(text, #"\b(?:FixtureLaunch|EnduragentCoachFixtures)\b"#)
		{
			try findings.report(file, "fixture-launch-debug-only")
		}
		if try isProof && !NodePath.basename(file).hasSameUnits(as: "TutorialHarness.swift")
			&& patterns.test(Self.sharedProofHelpers, text)
		{
			try findings.report(file, "ui-proof-shared-helpers")
		}
		if try isProof && patterns.test(Self.debugRowQuery, text) {
			try findings.report(file, "ui-proof-debug-scrolling")
		}
		if try isProof && patterns.test(#"\bXCTSkip(?:If|Unless)?\b"#, text) {
			try findings.report(file, "ui-proof-no-skips")
		}
		if try file.hasUnitSuffix(".swift") && hasExtraSecretStore(text) {
			try findings.report(file, "single-secret-store")
		}
		if try patterns.test(Self.waitSource, file) && hasUnboundedTestWait(text) {
			try findings.report(file, "test-wait-deadline")
		}
		if try patterns.test(Self.hangGuardSource, file) && hasLiteralTestHangGuard(text) {
			try findings.report(file, "test-hang-guard-duration")
		}
	}

	func checkContentRules(_ source: SourceFile) throws {
		let file = source.file
		let text = source.text
		if try patterns.test(#"\bi\d{8,9}\b"#, text) { try findings.report(file, "intervals-id") }
		if try patterns.test(Self.appSource, file) && patterns.test(Self.appNumberFormatting, text)
		{
			try findings.report(file, "app-number-formatting")
		}
		if try file.hasUnitSuffix(".swift") && patterns.test(#"swiftlint:(?:disable|enable)"#, text)
		{
			try findings.report(file, "lint-disable")
		}
		if try patterns.test(Self.recordSource, file)
			&& patterns.test(#"\b(?:public|open)\b|@_spi\b"#, text)
		{
			try findings.report(file, "records-package-only")
		}
		if file.hasSameUnits(as: Self.recordModel) { try checkLedgerIndexVersion(file, text) }
		if try file.hasSameUnits(as: Self.mailbox) && hasExposedMailboxState(text) {
			try findings.report(file, "mailbox-private-state")
		}
		if try patterns.test(Self.activityID, text) { try findings.report(file, "activity-id") }
		if try patterns.test(Self.fixture, file) && hasCurrentEraDate(text) {
			try findings.report(file, "fixture-date")
		}
		if try patterns.test(Self.secretShape, text) { try findings.report(file, "secret-shape") }
		if try publicText(file, text).contains(where: { try patterns.test(Self.language, $0) }) {
			try findings.report(file, "public-language")
		}
		if try patterns.test(Self.sentenceFile, file) {
			for sentence in sentences(try JSONValue.parse(text), key: "") {
				guard try patterns.test(Self.language, sentence.text) else { continue }
				try findings.report(file, "public-language", key: sentence.key)
			}
		}
	}

	private func hasCurrentEraDate(_ text: String) throws -> Bool {
		try patterns.matchAll(#"\b(\d{4})-\d{2}-\d{2}\b"#, text).contains {
			(Int($0.groups[1]) ?? 0) >= 2015
		}
	}

	private func sentences(_ value: JSONValue, key: String) -> [(key: String, text: String)] {
		if case .string(let text) = value { return [(key, text)] }
		return value.entries.flatMap { member in
			sentences(member.value, key: key.isEmpty ? member.key : "\(key).\(member.key)")
		}
	}

	private func publicText(_ file: String, _ text: String) throws -> [String] {
		if file.hasUnitSuffix(".md") && !NodePath.basename(file).hasSameUnits(as: "NOTICE.md") {
			return [
				try patterns.replaceAll(#"```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`]*`"#, text, with: "")
			]
		}
		if file.hasUnitSuffix(".swift") && file.range(of: "/Tests/", options: .literal) == nil {
			return try patterns.matchAll(Self.swiftCopy, text).map { $0.groups[1] }
		}
		return []
	}

	private func checkLedgerIndexVersion(_ file: String, _ text: String) throws {
		let versions = ["ledger-indexes-v1": ["deviceId,hlcWallMs,hlcLogical", "kind,chatId"]]
		let modifier = try patterns.exec(
			#"@Attribute\(\s*hashModifier:\s*"(ledger-indexes-v\d+)"\s*\)\s*var\s+deviceId\b"#, text
		)?.groups[1]
		let declarations = try patterns.matchAll(
			#"#Index\s*<\s*StoredAthleteRecord\s*>\s*\(([^)]*)\)"#, text)
		let indexes = try declarations.flatMap { declaration in
			try patterns.matchAll(#"\[([^\]]*)\]"#, declaration.groups[1]).map { fields in
				try patterns.replaceAll(#"\s|\\\."#, fields.groups[1], with: "")
			}
		}
		let expected = modifier.flatMap { versions[$0] }
		guard let expected, inUnitOrder(indexes).elementsEqual(inUnitOrder(expected)) else {
			try findings.report(file, "ledger-index-version")
			return
		}
	}

	private func inUnitOrder(_ values: [String]) -> [[UInt16]] {
		values.map { Array($0.utf16) }.sorted { $0.lexicographicallyPrecedes($1) }
	}
}
