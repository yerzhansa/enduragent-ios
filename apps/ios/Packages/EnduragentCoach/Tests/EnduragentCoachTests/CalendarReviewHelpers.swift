import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

func connectedTraining(_ client: any TrainingClient) -> TrainingConnection {
	.connected(
		ConnectedTraining(
			connection: testConnection.id, athlete: testAthlete, client: client))
}

func makeDesk(
	ledger: Ledger, clock: any EnduragentCoach.Clock,
	diagnostics: DiagnosticsLog? = nil
) -> WorkoutReviewDesk {
	WorkoutReviewDesk(
		ledger: ledger, clock: clock, diagnostics: diagnostics ?? DiagnosticsLog(clock: clock),
		training: { _ in .unconnected }, host: ImmediateExecutionHost())
}

func makeToolOffer(
	training: TrainingConnection, ledger: Ledger, clock: any EnduragentCoach.Clock,
	memory: MemoryView = MemoryView(sections: [:], todayNotes: nil, orphanNames: [])
) -> ToolOffer {
	ToolOffer(
		for: TurnReach(
			training: training, memory: memory, chat: .main, ledger: ledger, clock: clock,
			desk: makeDesk(ledger: ledger, clock: clock),
			plans: Plans(ledger: ledger, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			attempt: DraftKey(
				turn: TurnID(ulid: fixedUlid(1)), attempt: AttemptID(ulid: fixedUlid(2)))))
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

extension FakeIntervalsCall {
	var isWrite: Bool {
		switch self {
		case .createEvent, .updateEvent, .deleteEvent: true
		default: false
		}
	}
}

extension ReviewControlToken {
	func movedToAnotherChat(at head: ULID) throws -> ReviewControlToken {
		let moved = Delivery(
			ref: ReviewRef(
				chat: "elsewhere", review: ref.review, revision: ref.revision,
				delivery: ref.delivery),
			head: head, presence: .armed(secret))
		guard case .armed(_, let token) = moved.controls(.approveOrCancel) else {
			throw UnexpectedReview(detail: "an armed delivery gave no control")
		}
		return token
	}
}
