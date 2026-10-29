import EnduragentCoach

extension NamedProvider {
	public static let fixtureHost: NamedProvider = {
		do {
			return try NamedProvider(name: "Fixture Host", routingSlug: "fixture-host")
		} catch {
			fatalError("Fixture host is invalid: \(error)")
		}
	}()
}

extension ModelCatalog {
	public static let fixture: ModelCatalog = {
		do {
			return try ModelCatalog(
				revision: 1,
				entries: ["test/coach-model", "test/account-model", "fixture/openrouter-model"].map
				{
					try ModelCatalogEntry(
						id: ModelID(rawValue: $0),
						details: ModelDetails(displayName: $0, provider: .fixtureHost))
				})
		} catch {
			fatalError("Fixture model catalog is invalid: \(error)")
		}
	}()
}
