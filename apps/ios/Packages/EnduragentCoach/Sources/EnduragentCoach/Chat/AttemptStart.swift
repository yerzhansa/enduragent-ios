import Foundation

struct AttemptStart {
	let chat: ChatID
	let records: TurnRecords
	let environment: EnvironmentResolver
	let process: ProcessID

	func begin(
		_ facts: TurnFacts, stamp: OperationStamp, isolation: isolated (any Actor)? = #isolation
	) async -> TurnAttempt? {
		let attempt = stamp.attempt
		guard
			case .success(let claim) = records.writes(
				.claim(attempt, process: process), for: facts.turn)
		else { return nil }
		do {
			try await records.commit(claim, stamp: stamp)
		} catch {
			await records.settleUnsaved(
				facts.turn, attempt: attempt, .failed(.local(.recordStorage), saved: .none))
			return nil
		}
		switch await environment.resolve() {
		case .failure(let error):
			let unavailable = Settlement.failed(.model(.accessUnavailable(error)), saved: .none)
			await records.settle(facts.turn, .settle(attempt, unavailable), stamp: stamp)
			return nil
		case .success(let resolved):
			return environment.attempt(of: facts, attempt: attempt, chat: chat, in: resolved)
		}
	}
}
