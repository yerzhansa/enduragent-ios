#if os(macOS)
	import Foundation
	import Testing

	@testable import EnduragentCoach

	@Suite(.serialized) struct LiveCoachCheck {
		@Test(.enabled(if: LiveCheck.selected == .coach), .timeLimit(.minutes(60)))
		func coachSuiteAgainstTheRealModel() async throws {
			let started = Date()
			let keys: [LiveKey: String]
			do {
				keys = try LiveKey.secrets(LiveKey.allCases, lookUp: LiveKey.lookUpInKeychain)
			} catch let stop as LiveCheckStop {
				Issue.record(Comment(rawValue: stop.description))
				return
			}
			let intervalsKey = try #require(keys[.intervals])
			let folder = try LiveRunFolder(kind: .coach, startedAt: started)
			let ledger = try LiveSpendLedger(
				file: folder.logs.appending(path: "spend.tsv"), limit: LiveSpendLedger.unitLimit)
			defer { FileHandle.standardOutput.write(Data((ledger.statement + "\n").utf8)) }
			let today = IntervalsPolicy.today(now: started, timeZone: .current)
			let account = IntervalsRESTClient(credential: .apiKey(intervalsKey))
			let profile = try await account.profile()
			let listing = try await account.activities(
				in: try ReadRange(oldest: today.adding(days: -29), newest: today, today: today))
			let bench = LiveCoachBench(
				intervalsKey: intervalsKey, openRouterKey: try #require(keys[.openRouter]),
				athlete: IntervalsAthleteID(rawValue: profile.id),
				model: try LiveCoachBench.builtInModel(), ledger: ledger, today: today,
				modelTransport: { diagnostics in
					OpenRouterTransport(
						baseURL: ModelService.openRouterAPI, diagnostics: diagnostics)
				},
				accountReads: { credential, selection, clock in
					IntervalsRESTClient(credential: credential, athlete: selection, clock: clock)
				})
			let plan = LiveCoachPlan(listing: listing, today: today)
			var report = LiveCoachReport(unavailable: plan.unavailable, spentBefore: ledger.total)
			for scenario in plan.scenarios {
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
			try folder.write(
				report.markdown(total: ledger.total, limit: ledger.limit), to: "summary.md")
			for failure in report.failures(capReached: ledger.capReached) {
				Issue.record(Comment(rawValue: failure))
			}
		}
	}
#endif

struct LiveCoachReport {
	let unavailable: [String]
	let spentBefore: Double
	var results: [(name: String, runs: [LiveScenarioRun])] = []
	var stoppedBefore: String?

	func verdict(of runs: [LiveScenarioRun]) -> String {
		switch (runs.first?.passed, runs.dropFirst().first?.passed) {
		case (true?, _): "pass"
		case (false?, true?): "flaky: failed once, passed on the rerun"
		case (false?, false?): "fail: failed twice"
		default: "fail: not rerun because the spend cap was reached"
		}
	}

	func failures(capReached: Bool) -> [String] {
		var failures = results.compactMap { result -> String? in
			guard result.runs.allSatisfy({ !$0.passed }) else { return nil }
			let reasons = result.runs.flatMap { run in
				run.violations.map { "run \(run.attempt): \($0)" }
			}
			return "\(result.name): \(reasons.joined(separator: "; "))"
		}
		failures += unavailable.map { "not available, so not covered: \($0)" }
		if capReached {
			failures.append(
				"The spend cap stopped the suite\(stoppedBefore.map { " before \($0)" } ?? "").")
		}
		return failures
	}

	func markdown(total: Double, limit: Double) -> String {
		var lines = [
			"# Live coach suite", "",
			String(
				format: "Spend: $%.4f this run, $%.4f of $%.2f in total.", total - spentBefore,
				total, limit),
			"", "| Scenario | Run 1 | Run 2 | Verdict |", "| --- | --- | --- | --- |",
		]
		for result in results {
			let outcomes = result.runs.map { $0.passed ? "pass" : "fail" }
			lines.append(
				"| \(result.name) | \(outcomes.first ?? "") | \(outcomes.dropFirst().first ?? "not run") | \(verdict(of: result.runs)) |"
			)
		}
		if let stoppedBefore { lines += ["", "Stopped by the spend cap before \(stoppedBefore)."] }
		if !unavailable.isEmpty {
			lines += ["", "## Not available in this account", ""] + unavailable.map { "- \($0)" }
		}
		for result in results where !result.runs.allSatisfy(\.passed) {
			lines += ["", "## \(result.name)", ""]
			for run in result.runs {
				lines += run.violations.map { "- run \(run.attempt): \($0)" }
			}
		}
		return lines.joined(separator: "\n") + "\n"
	}
}
