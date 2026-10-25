#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures
	import Foundation

	actor FixturePlanTapDriver {
		static let expiryAdvance: TimeInterval = 660
		static let replacementWeeks = 10

		private let tap: FixturePlanTap
		private let calendar: FixedClock
		private var pending = true

		init(tap: FixturePlanTap, calendar: FixedClock) {
			self.tap = tap
			self.calendar = calendar
		}

		func decisions(for decision: PlanDecision, coach: Coach) async -> [PlanDecision] {
			guard case .save(let token) = decision else { return [decision] }
			switch tap {
			case .twice:
				return [decision, decision]
			case .expired where pending:
				pending = false
				calendar.advance(by: Self.expiryAdvance)
			case .replaced where pending:
				pending = false
				await replace(token.ref, coach: coach)
			case .expired, .replaced:
				break
			}
			return [decision]
		}

		private func replace(_ ref: PlanCardRef, coach: Coach) async {
			let directive = FirstWeekFixture.planSaveDirective(weeks: Self.replacementWeeks)
			do {
				_ = try await coach.send(Draft(id: DraftID(), text: directive), to: ref.chat)
			} catch {
				fatalError("The replaced-tap fixture could not send its second plan: \(error)")
			}
			for await snapshot in await coach.observe(ref.chat) {
				let replaced = snapshot.plans.contains { card in
					guard card.id != ref.confirmation, case .waiting = card.state else {
						return false
					}
					return true
				}
				if replaced, snapshot.turns.allSatisfy(\.state.isSettled) { return }
			}
		}
	}
#endif
