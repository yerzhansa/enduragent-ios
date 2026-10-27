#if os(macOS)
	import Foundation
	import Testing

	@testable import EnduragentCoach

	@Suite(.serialized) struct LiveCoachCheck {
		@Test(.enabled(if: LiveCheck.selected == .coach), .timeLimit(.minutes(60)))
		func coachSuiteAgainstTheRealModel() async throws {
			let run = try await LiveCoachSuite.live.run(
				{ account, today in
					let plan = LiveCoachPlan(
						listing: try await account.activities(
							in: try ReadRange(
								oldest: today.adding(days: -29), newest: today, today: today)),
						calendar: try await account.listEvents(
							in: try LiveSeedCalendar.window(around: today)),
						today: today)
					return (plan.scenarios, plan.unavailable)
				}, check: .coach, title: "Live coach suite")
			for failure in run.failures {
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
	var leaks: [String] = []

	static func leaks(in folder: LiveRunFolder, of keys: [LiveKey: String]) throws -> [String] {
		try keys.sorted { $0.key.rawValue < $1.key.rawValue }.flatMap { key, secret in
			try folder.files(containing: secret).map {
				"\($0): the saved file holds the key of \(key.rawValue)"
			}
		}
	}

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
		failures += leaks
		if capReached {
			failures.append(
				"The spend cap stopped the suite\(stoppedBefore.map { " before \($0)" } ?? "").")
		}
		return failures
	}

	func markdown(title: String, milestone: LiveMilestone, total: Double, limit: Double) -> String {
		var lines = [
			"# \(title)", "",
			"Spend for \(milestone.rawValue): "
				+ String(
					format: "$%.4f this run, $%.4f of $%.2f in total.", total - spentBefore, total,
					limit),
			"", "| Scenario | Run 1 | Run 2 | Verdict |", "| --- | --- | --- | --- |",
		]
		for result in results {
			let outcomes = result.runs.map { $0.passed ? "pass" : "fail" }
			lines.append(
				"| \(result.name) | \(outcomes.first ?? "") | \(outcomes.dropFirst().first ?? "not run") | \(verdict(of: result.runs)) |"
			)
		}
		if let stoppedBefore { lines += ["", "Stopped by the spend cap before \(stoppedBefore)."] }
		if !leaks.isEmpty { lines += ["", "## Key leaks", ""] + leaks.map { "- \($0)" } }
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
