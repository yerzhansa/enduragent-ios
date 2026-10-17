import Foundation

extension Coach {
	func recoverReviews() async {
		guard !lifetime.terminating else { return }
		observeReviews()
		await desk.recover()
	}

	func observeReviews() {
		guard reviewObservation == nil, !lifetime.terminating else { return }
		reviewObservation = Task { [weak self, changes = desk.changes] in
			for await _ in changes {
				guard !Task.isCancelled else { return }
				await self?.refreshReviews()
			}
		}
	}

	private func refreshReviews() async {
		guard !lifetime.terminating else { return }
		for mailbox in mailboxes.values {
			_ = await mailbox.reviewChanged()
		}
		await publishStatus()
	}
}
