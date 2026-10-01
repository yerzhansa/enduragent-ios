import Foundation
import Testing

@testable import EnduragentCoach

extension RetryLadderTests {
	@Test(.timeLimit(.minutes(1)), arguments: ProposalEntryPoint.allCases)
	func proposalEntryPointsRespectApprovedRetry(entry: ProposalEntryPoint) async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		transport.script =
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ [.text("Second."), .finish(reason: .stop)]
		let model = HeldApprovalTransport(base: transport, clock: held) { index, request in
			request.charge == .chatAttempt && index == 3 ? .seconds(11) : nil
		}
		let coach = await heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		held.release(.seconds(7))
		try await held.waitUntilHeld(.seconds(11))
		let scope = try #require(try await coach.mailbox(for: .main).reviewScope)
		let first = await coach.decide(.approve(token), in: .main)
		let probeStore = InMemoryRecordLog()
		let ledger = Ledger(log: probeStore, clock: held, diagnostics: DiagnosticsLog(clock: held))
		let runtime = ToolRuntime(intervals: intervals, ledger: ledger, clock: held)
		let arguments = try JSONValue.parse(
			#"{"date":"1998-06-16","name":"Strength","description":"Three sets"}"#)
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
					summary: "Strength", description: "Three sets", now: held.now, ledger: ledger,
					scope: scope)
			}
		}
		#expect(
			try await probeStore.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.isEmpty)
		held.release(.seconds(11))
		try await expectSingleApproval(
			turn: turn, first: first, coach: coach,
			intervals: intervals, savedRequests: 3)
	}
}

enum ProposalEntryPoint: CaseIterable {
	case runtime
	case gatedTool
	case proposalPolicy
}
