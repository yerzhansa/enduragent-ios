import EnduragentCoach
import Observation

@MainActor
@Observable
final class PlanDecisions {
	private(set) var answers: [PlanConfirmationID: PlanAnswer] = [:]
	private(set) var deciding = false
	private let services: AppServices

	init(services: AppServices) {
		self.services = services
	}

	func present(_ ref: PlanCardRef) async {
		_ = await services.coach.decide(.presented(ref), in: ref.chat)
	}

	func decide(_ decision: PlanDecision) async {
		guard !deciding else { return }
		deciding = true
		defer { deciding = false }
		let ref = decision.ref
		for tap in await taps(of: decision) {
			answers[ref.confirmation] = PlanAnswer(await services.coach.decide(tap, in: ref.chat))
		}
	}

	private func taps(of decision: PlanDecision) async -> [PlanDecision] {
		#if DEBUG
			if let driver = services.fixture?.planTapDriver {
				return await driver.decisions(for: decision, coach: services.coach)
			}
		#endif
		return [decision]
	}
}

extension PlanDecision {
	fileprivate var ref: PlanCardRef {
		switch self {
		case .presented(let ref): ref
		case .save(let token), .cancel(let token): token.ref
		}
	}
}
