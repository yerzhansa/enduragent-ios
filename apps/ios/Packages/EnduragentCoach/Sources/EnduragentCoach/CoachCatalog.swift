import Foundation

extension Coach {
	func observeCatalog() {
		guard catalogObservation == nil else { return }
		let updates = catalogs.updates
		catalogObservation = Task { [weak self] in
			for await _ in updates {
				guard let self, !Task.isCancelled else { return }
				await self.publishStatus()
			}
		}
	}
}
