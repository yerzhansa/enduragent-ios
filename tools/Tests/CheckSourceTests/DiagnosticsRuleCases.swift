extension SourceCases {
	static let failureCodeSource = "\(coachSources)/Diagnostics/FailureCode.swift"
	static let newFailureSource = "\(coachSources)/Support/NewFailure.swift"

	static func failureCode(naming rawValues: [String]) -> String {
		"package enum FailureCode: Sendable, Equatable {\n\tcase ledger(LedgerFailure)\n"
			+ "\tcase type(PackageErrorType)\n}\n\n"
			+ "package enum PackageErrorType: String, Sendable, CaseIterable {\n"
			+ rawValues.enumerated().map { "\tcase named\($0.offset) = \"\($0.element)\"\n" }
			.joined() + "}\n"
	}

	static let failureCodeCoversErrors: [SourceCase] = [
		.rejects(
			"rejects a package error type that no failure code names",
			[
				failureCodeSource: failureCode(naming: ["OtherFailure"]),
				newFailureSource: "package struct NewFailure: Error, Sendable {}\n",
			],
			finding: "failure-code-covers-errors",
			findingLines: [#""\#(newFailureSource)" [failure-code-covers-errors] "NewFailure""#]),
		.accepts(
			"accepts a package error type that PackageErrorType names",
			[
				failureCodeSource: failureCode(naming: ["NewFailure"]),
				newFailureSource: "package struct NewFailure: Error, Sendable {}\n",
			]),
		.accepts(
			"accepts a package error type that a FailureCode case carries",
			[
				failureCodeSource: failureCode(naming: []),
				"\(coachSources)/Records/Ledger.swift":
					"package enum LedgerFailure: Error, Sendable, Equatable {\n\tcase unavailable\n}\n",
			]),
		.rejects(
			"rejects a nested error type by its outer type and its own name",
			[
				failureCodeSource: failureCode(naming: ["Failure"]),
				newFailureSource:
					"struct Outer {\n\tlet value: Int\n\n\tenum Failure: Error {\n\t\tcase lost\n\t}\n}\n",
			],
			finding: "failure-code-covers-errors",
			findingLines: [#""\#(newFailureSource)" [failure-code-covers-errors] "Outer.Failure""#]),
		.rejects(
			"rejects an error type nested in an extension by the extended type's name",
			[
				failureCodeSource: failureCode(naming: []),
				newFailureSource:
					"extension Outer {\n\tfunc run() {\n\t\tif ready { start() }\n\t}\n\n"
					+ "\tstruct Failure: Swift.Error, Sendable {}\n}\n",
			],
			finding: "failure-code-covers-errors",
			findingLines: [#""\#(newFailureSource)" [failure-code-covers-errors] "Outer.Failure""#]),
		.accepts(
			"accepts a nested error type that PackageErrorType names with its outer type",
			[
				failureCodeSource: failureCode(naming: ["Outer.Failure"]),
				newFailureSource:
					"struct Outer {\n\tenum Failure: Error {\n\t\tcase lost\n\t}\n}\n",
			]),
		.accepts(
			"accepts private error types and error types outside the package sources",
			[
				failureCodeSource: failureCode(naming: []),
				newFailureSource:
					"private enum Hidden: Error {}\n\nfileprivate struct Local: Error {}\n\n"
					+ "private struct Holder {\n\tstruct Inner: Error {}\n}\n\n"
					+ "struct Plain: Sendable {\n\tlet text = \"enum Quoted: Error {}\"\n}\n",
				"\(coachTests)/SampleTests.swift": "struct SampleFailure: Error {}\n",
				"\(coachFixtures)/FixtureFailure.swift":
					"package struct FixtureFailure: Error {}\n",
			]),
	]

	static let supportServiceSource = "\(coachSources)/Support/SupportService.swift"
	static let appProbeSource = "apps/ios/Enduragent/App/LogProbe.swift"

	static let diagnosticsLogOneMaker: [SourceCase] = [
		.rejects(
			"rejects an app file that makes a diagnostics log",
			[appProbeSource: "let log = DiagnosticsLog(clock: clock, storage: storage)\n"],
			finding: "diagnostics-log-one-maker",
			findingLines: [#""\#(appProbeSource)" [diagnostics-log-one-maker]"#]),
		.rejects(
			"rejects a package file that makes a diagnostics log through init",
			[
				"\(coachSources)/Coach.swift":
					"let diagnostics = DiagnosticsLog . init(clock: clock, storage: storage)\n"
			],
			finding: "diagnostics-log-one-maker",
			findingLines: [#""\#(coachSources)/Coach.swift" [diagnostics-log-one-maker]"#]),
		.accepts(
			"accepts the support service, tests, fixtures and names of the type",
			[
				supportServiceSource:
					"func openLog(clock: any Clock) -> DiagnosticsLog {\n"
					+ "\tDiagnosticsLog(clock: clock, storage: journal)\n}\n",
				"\(coachSources)/Coach.swift":
					"let diagnostics: DiagnosticsLog\n"
					+ "let make: @Sendable (DiagnosticsLog) -> Int\n"
					+ "let text = \"DiagnosticsLog(clock:)\"\n",
				"\(coachTests)/LogTests.swift": "let log = DiagnosticsLog(clock: clock)\n",
				"\(coachFixtures)/MemoryJournalStorage.swift":
					"let log = DiagnosticsLog(clock: clock, storage: MemoryJournalStorage())\n",
			]),
	]
}
