import Foundation

extension CredentialVault {
	package func modelAccess(builtInModel: ModelID) throws(AccessUnavailable) -> ResolvedAccess {
		guard let key = try creditsKey() else { throw .notConfigured(.credits) }
		let entry = try builtInEntry(builtInModel)
		return ResolvedAccess(
			credential: ProviderCredential(secret: key.value, method: .credits),
			model: entry.id, provider: entry.details.provider)
	}

	package func accessStatus(builtInModel: ModelID, consent: ProviderConsent? = nil)
		-> AccessStatus
	{
		let availability: AccessAvailability
		do {
			availability = try creditsKey() == nil ? .needsSetup : .ready
		} catch {
			availability = .unavailable(error)
		}
		return AccessStatus(
			availability: availability, model: builtInModel,
			consent: accessConsent(builtInModel: builtInModel, recorded: consent))
	}

	func builtInEntry(_ model: ModelID) throws(AccessUnavailable) -> ModelCatalogEntry {
		do {
			return try catalog.choice(
				model,
				unlisted: catalogs.bundled.entries[model] ?? ModelCatalog.bundled.entries[model])
		} catch {
			throw .malformedStoredCredential(.accessSelection)
		}
	}
}
