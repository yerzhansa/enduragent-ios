import Foundation
import Testing

@testable import EnduragentCoach

extension RetryLadderTests {
	@Test(.timeLimit(.minutes(1)), arguments: ProposalEntryPoint.allCases)
	func proposalEntryPointsRespectApprovedRetry(entry: ProposalEntryPoint) async throws {
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let account = TrainingAccount.intervals(connection: ConnectionID(), athlete: nil)
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let scope = TurnScope(
			stamp: testStamp(account: account), policy: .npm, ladder: .npm, uptime: clock.uptime)
		let runtime = ToolRuntime(intervals: intervals, ledger: ledger, clock: clock)
		let arguments = try JSONValue.parse(
			#"{"date":"1998-06-16","name":"Strength","description":"Three sets"}"#)
		try await scope.chargeAttempt()
		_ = try await runtime.execute(
			name: .intervalsCreateStrengthWorkout, arguments: arguments, chatId: .main, scope: scope
		)
		let reviews = SingleProposalReviews(
			ledger: ledger, clock: clock, diagnostics: DiagnosticsLog(clock: clock),
			training: { TrainingConnection(account: account, client: intervals) })
		let review = try #require(try await reviews.snapshot(chat: .main))
		#expect(
			await reviews.decide(.presented(review.ref), chat: .main, scope: scope)
				== .presentationRecorded)
		let token = try #require(try await reviews.snapshot(chat: .main)?.token)
		#expect(
			await reviews.decide(.approve(token), chat: .main, scope: scope)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		try await scope.chargeAttempt()
		await #expect(throws: SavedWorkReached.self) {
			switch entry {
			case .runtime:
				_ = try await runtime.execute(
					name: .intervalsCreateStrengthWorkout,
					arguments: arguments, chatId: .main, scope: scope)
			case .gatedTool:
				_ = try await runtime.executeGated(
					.intervalsCreateStrengthWorkout,
					arguments: arguments, chatId: .main, scope: scope)
			case .proposalPolicy:
				_ = try await ProposalPolicy.propose(
					chatId: .main, tool: .intervalsCreateStrengthWorkout,
					input: .createStrengthWorkout(
						date: "1998-06-16", name: "Strength", description: "Three sets"),
					summary: "Strength", description: "Three sets", now: clock.now, ledger: ledger,
					scope: scope)
			}
		}
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.count == 1)
		#expect(intervals.calls.filter(\.isWrite).count == 1)
		#expect(try await reviews.snapshot(chat: .main) == nil)
	}
}

enum ProposalEntryPoint: CaseIterable {
	case runtime
	case gatedTool
	case proposalPolicy
}
