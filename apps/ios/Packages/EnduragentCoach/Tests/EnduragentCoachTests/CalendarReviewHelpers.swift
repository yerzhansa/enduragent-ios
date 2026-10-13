import EnduragentCoachFixtures
import Foundation

@testable import EnduragentCoach

func makeReviews(
	ledger: Ledger, clock: any EnduragentCoach.Clock,
	intervals: any TrainingClient = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
) -> SingleProposalReviews {
	SingleProposalReviews(
		ledger: ledger, clock: clock, diagnostics: DiagnosticsLog(clock: clock),
		training: { _ in
			TrainingConnection(account: .unconnected, client: intervals)
		})
}

func makeToolRuntime(
	intervals: any TrainingClient, ledger: Ledger, clock: any EnduragentCoach.Clock
) -> ToolRuntime {
	ToolRuntime(
		intervals: intervals, ledger: ledger, clock: clock,
		reviews: makeReviews(ledger: ledger, clock: clock, intervals: intervals))
}
