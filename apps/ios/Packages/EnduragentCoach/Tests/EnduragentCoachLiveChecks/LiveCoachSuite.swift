import Foundation

@testable import EnduragentCoach

struct LiveSuiteRun: Sendable {
	let folder: LiveRunFolder
	let failures: [String]
}

struct LiveCoachSuite: Sendable {
	typealias Scenarios =
		@Sendable (any TrainingClient, CivilDate) async throws -> (
			scenarios: [LiveScenario], unavailable: [String]
		)

	let lookUp: @Sendable (LiveKey) throws -> KeychainLookup
	let folder: @Sendable (LiveCheck, Date) throws -> LiveRunFolder
	let modelTransport: @Sendable (DiagnosticsLog) -> any ModelTransport
	let accountReads: TrainingService.ClientFactory
	let say: @Sendable (String) -> Void

	func run(_ scenarios: Scenarios, check: LiveCheck, title: String) async throws -> LiveSuiteRun {
		guard let spend = check.spend else {
			throw LiveCheckStop(
				description: "make live-\(check.rawValue) calls no model, so it has no spend cap.")
		}
		let started = Date()
		let keys = try LiveKey.secrets(LiveKey.allCases, lookUp: lookUp)
		guard let intervalsKey = keys[.intervals], let openRouterKey = keys[.openRouter] else {
			throw LiveCheckStop(description: "The Keychain lookup returned no key.")
		}
		let folder = try self.folder(check, started)
		let ledger = try LiveSpendLedger(
			file: folder.logs.appending(path: "spend.tsv"), milestone: spend.milestone,
			limit: spend.limit)
		say(ledger.statement)
		defer { say(ledger.statement) }
		let today = IntervalsPolicy.today(now: started, timeZone: .current)
		let account = accountReads(.apiKey(intervalsKey), .keyOwner)
		let profile = try await account.profile()
		let planned = try await scenarios(account, today)
		let bench = LiveCoachBench(
			intervalsKey: intervalsKey, openRouterKey: openRouterKey,
			athlete: IntervalsAthleteID(rawValue: profile.id),
			model: try LiveCoachBench.builtInModel(), ledger: ledger, today: today,
			modelTransport: modelTransport, accountReads: accountReads,
			seedLedger: folder.logs.appending(path: "seed/ledger.tsv"))
		var report = LiveCoachReport(unavailable: planned.unavailable, spentBefore: ledger.total)
		for scenario in planned.scenarios {
			guard !ledger.capReached else {
				report.stoppedBefore = scenario.name
				break
			}
			var runs = [try await bench.run(scenario, attempt: 1)]
			if !runs[0].passed, !ledger.capReached {
				runs.append(try await bench.run(scenario, attempt: 2))
			}
			for run in runs {
				try folder.write(run.transcript, to: "\(scenario.name)-run\(run.attempt).md")
			}
			report.results.append((scenario.name, runs))
		}
		report.leaks = try LiveCoachReport.leaks(in: folder, of: keys)
		try folder.write(
			report.markdown(
				title: title, milestone: ledger.milestone, total: ledger.total, limit: ledger.limit),
			to: "summary.md")
		report.leaks += try LiveCoachReport.leaks(in: folder, of: keys).filter {
			$0.hasPrefix("summary.md:")
		}
		return LiveSuiteRun(
			folder: folder, failures: report.failures(capReached: ledger.capReached))
	}
}

#if os(macOS)
	extension LiveCoachSuite {
		static let live = LiveCoachSuite(
			lookUp: LiveKey.lookUpInKeychain,
			folder: { check, started in try LiveRunFolder(kind: check, startedAt: started) },
			modelTransport: { diagnostics in
				OpenRouterTransport(baseURL: ModelService.openRouterAPI, diagnostics: diagnostics)
			},
			accountReads: { credential, selection in
				IntervalsRESTClient(credential: credential, athlete: selection)
			},
			say: { line in FileHandle.standardOutput.write(Data((line + "\n").utf8)) })
	}
#endif
