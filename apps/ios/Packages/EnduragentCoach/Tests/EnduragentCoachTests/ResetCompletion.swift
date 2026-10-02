import EnduragentCoachFixtures
import Synchronization
import Testing

@testable import EnduragentCoach

enum ResetCompletion: Sendable, Equatable {
	case started(memory: MemorySaveResult)
	case notStarted(CoachFailure)
}

extension Coach {
	func resetAndSettle(in chat: ChatID) async -> ResetCompletion {
		await resetCompletion(await startNewConversation(in: chat), in: chat)
	}

	func resetCompletion(_ admission: ResetAdmission, in chat: ChatID) async -> ResetCompletion {
		guard case .accepted(let reset) = admission else {
			if case .notStarted(let failure) = admission { return .notStarted(failure) }
			preconditionFailure("Reset admission must be accepted or refused")
		}
		do {
			let completed = try await firstSnapshot(in: await observe(chat), within: .hangGuard) {
				if case .failed(let failed, _) = $0.reset, failed == reset { return true }
				if case .afterNewConversation(let opened, _) = $0.opening {
					return opened == reset
				}
				return false
			}
			let latest = await currentSnapshot(chat)
			let snapshot = try #require(
				completed, "Reset \(reset) latest snapshot \(String(describing: latest))")
			if case .failed(_, let failure) = snapshot.reset { return .notStarted(failure) }
			guard case .afterNewConversation(_, let memory) = snapshot.opening else {
				preconditionFailure("Reset completion must contain its opening")
			}
			return .started(memory: memory)
		} catch {
			Issue.record(error)
			return .notStarted(.local(.recordStorage))
		}
	}
}

func startNewConversation(on coach: Coach) -> PendingOutcome {
	let pending = PendingOutcome()
	Task { pending.land(await coach.resetAndSettle(in: .main)) }
	return pending
}

func outcome(_ pending: PendingOutcome) async throws -> ResetCompletion? {
	try await pending.ready.waitUnlessCancelled()
	return pending.landed
}

final class PendingOutcome: Sendable {
	private let outcome = Mutex<ResetCompletion?>(nil)
	let ready = Gate()

	var landed: ResetCompletion? {
		outcome.withLock { $0 }
	}

	func land(_ value: ResetCompletion) {
		outcome.withLock { $0 = value }
		ready.release()
	}
}
