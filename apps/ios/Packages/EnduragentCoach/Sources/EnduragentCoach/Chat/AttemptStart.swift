import Foundation

struct AttemptStart {
	let chat: ChatID
	let records: ChatRecords
	let environment: EnvironmentResolver
	let process: ProcessID

	func begin(
		_ facts: TurnFacts, origin: AttemptOrigin,
		resolution: Result<AttemptEnvironment, AccessUnavailable>,
		stamp: OperationStamp, lease: LeaseKind, isolation: isolated (any Actor)? = #isolation
	) async -> TurnAttempt? {
		let attempt = stamp.attempt
		guard
			case .success(let claim) = records.writes(
				.claim(attempt, process: process, lease: lease), for: facts.turn)
		else { return nil }
		do {
			try await records.commit(claim, stamp: stamp)
		} catch {
			await records.settleUnsaved(
				facts.turn, attempt: attempt, .failed(.local(.recordStorage), saved: .none))
			return nil
		}
		switch resolution {
		case .failure(let error):
			let unavailable = Settlement.failed(.model(.accessUnavailable(error)), saved: .none)
			await records.settle(facts.turn, .settle(attempt, unavailable), stamp: stamp)
			return nil
		case .success(let resolved):
			return environment.attempt(
				of: facts, attempt: attempt, origin: origin, chat: chat, process: process,
				in: resolved)
		}
	}
}
