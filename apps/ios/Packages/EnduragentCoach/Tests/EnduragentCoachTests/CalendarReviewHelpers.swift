import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

func connectedTraining(_ client: any TrainingClient) -> TrainingConnection {
	.connected(
		ConnectedTraining(
			connection: testConnection.id, athlete: testConnection.resolvedAthlete,
			client: client))
}

func makeReviews(
	ledger: Ledger, clock: any EnduragentCoach.Clock,
	intervals: any TrainingClient = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
) -> SingleProposalReviews {
	SingleProposalReviews(
		ledger: ledger, clock: clock, diagnostics: DiagnosticsLog(clock: clock),
		training: { _ in connectedTraining(intervals) })
}

func makeToolOffer(
	training: TrainingConnection, ledger: Ledger, clock: any EnduragentCoach.Clock,
	memory: MemoryView = MemoryView(
		sections: [:], todayNotes: nil, planHeadline: nil, orphanNames: [])
) -> ToolOffer {
	ToolOffer(
		for: TurnReach(
			training: training, memory: memory, chat: .main, ledger: ledger, clock: clock,
			reviews: makeReviews(ledger: ledger, clock: clock)))
}

func makeOfferedTools(
	intervals: any TrainingClient, ledger: Ledger, clock: any EnduragentCoach.Clock
) -> OfferedTools {
	OfferedTools(
		offer: makeToolOffer(training: connectedTraining(intervals), ledger: ledger, clock: clock))
}

struct OfferedTools {
	let offer: ToolOffer

	func execute(name: ToolName, arguments: JSONValue, scope: TurnScope) async throws
		-> ToolExecution
	{
		try await ToolRuntime.execute(
			try #require(offer.tool(named: name.rawValue)), arguments: arguments, scope: scope)
	}
}
