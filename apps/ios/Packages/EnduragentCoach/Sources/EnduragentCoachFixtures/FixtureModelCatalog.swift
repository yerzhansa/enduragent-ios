import EnduragentCoach

extension ModelCatalog {
	public static let fixture: ModelCatalog = {
		do {
			let provider = try NamedProvider(name: "Fixture Host", routingSlug: "fixture-host")
			return try ModelCatalog(
				revision: 1,
				entries: ["test/coach-model", "test/account-model", "fixture/openrouter-model"].map
				{
					try ModelCatalogEntry(
						id: ModelID(rawValue: $0),
						details: ModelDetails(displayName: $0, provider: provider))
				})
		} catch {
			fatalError("Fixture model catalog is invalid: \(error)")
		}
	}()
}
