import Foundation

struct AttemptStart {
	let chat: ChatID
	let ledger: Ledger
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
			case .success(let claim) = TurnLifecycle.claim(
				attempt, on: records.conversation.turn(facts.turn), chat: chat,
				device: ledger.deviceId, process: process, lease: lease)
		else { return nil }
		do {
			records.apply(try await ledger.commit(local: [.turnClaim(claim)], stamp: stamp))
			records.apply(
				try await ledger.commit(
					synced: [
						.attemptQuestion(
							AttemptQuestionBody(
								chatId: chat, turn: facts.turn, athleteText: facts.requestText))
					], stamp: stamp))
		} catch {
			await records.settleUnsaved(
				facts.turn, attempt: attempt, .failed(.local(.recordStorage), saved: .none))
			return nil
		}
		switch resolution {
		case .failure(let error):
			let unavailable = Settlement.failed(.model(.accessUnavailable(error)), saved: .none)
			await records.settle(
				TurnLifecycle.settled(
					attempt, unavailable, on: records.conversation.turn(facts.turn), chat: chat),
				stamp: stamp)
			return nil
		case .success(let resolved):
			return environment.attempt(
				of: facts, attempt: attempt, origin: origin, chat: chat, process: process,
				in: resolved)
		}
	}
}
