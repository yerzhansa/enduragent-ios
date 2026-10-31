import Foundation

extension Coach {
	public func decide(_ decision: PlanDecision, in chat: ChatID) async -> PlanDecisionOutcome {
		let mailbox: ChatMailbox
		do {
			mailbox = try await self.mailbox(for: chat)
		} catch {
			diagnostics.record(.recoveryUnavailable(error))
			return .storageUnavailable
		}
		return await mailbox.decide(decision)
	}

	func recoverPlans() async {
		guard !lifetime.terminating else { return }
		observePlans()
		await plans.recover()
		for mailbox in mailboxes.values {
			await mailbox.plansChanged()
		}
	}

	func observePlans() {
		guard planObservation == nil, !lifetime.terminating else { return }
		planObservation = Task { [weak self, changes = plans.changes] in
			for await chat in changes {
				guard !Task.isCancelled else { return }
				await self?.refreshPlans(in: chat)
			}
		}
	}

	private func refreshPlans(in chat: ChatID) async {
		guard !lifetime.terminating else { return }
		await mailboxes[chat]?.plansChanged()
	}
}
