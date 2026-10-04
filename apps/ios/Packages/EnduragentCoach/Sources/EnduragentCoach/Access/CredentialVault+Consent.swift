import Foundation

struct ConsentContext: Sendable {
	let base: SavedAccessReference?
	let challenge: ConsentChallenge
}

extension CredentialVault {
	func consentTarget(builtInModel: ModelID) throws(AccessUnavailable) -> ConsentTarget {
		let saved = try keychain(.accessSelection) { try store.accessSelection() }
		return try consentTarget(for: saved, builtInModel: builtInModel)
	}

	func consentTarget(for saved: SavedAccessReference?, builtInModel: ModelID)
		throws(AccessUnavailable) -> ConsentTarget
	{
		switch saved?.value {
		case nil, .credits?:
			do {
				return ConsentTarget(method: .credits, entry: try creditsEntry(builtInModel))
			} catch {
				throw .malformedStoredCredential(.accessSelection)
			}
		case .openRouter(let reference)?:
			return ConsentTarget(method: .openRouterAccount, entry: try savedEntry(reference))
		}
	}

	func accessConsent(builtInModel: ModelID, recorded: ProviderConsent?) -> AccessConsent {
		do {
			let saved = try keychain(.accessSelection) { try store.accessSelection() }
			if let pending = pendingModelChoice {
				if saved == pending.base { return .required(pending.challenge) }
				pendingModelChoice = nil
			}
			let target = try consentTarget(for: saved, builtInModel: builtInModel)
			if let recorded, recorded.authorizes(target) { return .accepted(recorded) }
			if let context = consentContext, context.base == saved,
				context.challenge.target == target
			{
				return .required(context.challenge)
			}
			let challenge = ConsentChallenge(target: target, generation: UUID())
			consentContext = ConsentContext(base: saved, challenge: challenge)
			return .required(challenge)
		} catch {
			consentContext = nil
			pendingModelChoice = nil
			return .unavailable
		}
	}

	func validateConsent(_ challenge: ConsentChallenge, builtInModel: ModelID)
		throws(ConsentWriteFailure)
	{
		guard
			case .required(let current) = accessConsent(builtInModel: builtInModel, recorded: nil),
			current == challenge
		else { throw .staleChallenge }
	}

	func finishConsent(_ challenge: ConsentChallenge, builtInModel: ModelID)
		throws(ConsentWriteFailure)
	{
		try validateConsent(challenge, builtInModel: builtInModel)
		if let pending = pendingModelChoice {
			do {
				guard case .openRouter(let reference) = pending.base?.value else {
					throw ConsentWriteFailure.staleChallenge
				}
				try keychain(.accessSelection) {
					try store.storeAccessSelection(
						.init(
							.openRouter(
								SavedOpenRouterReference(
									credential: reference.credential,
									model: challenge.target.entry.id,
									details: challenge.target.entry.details))))
				}
			} catch let failure as ConsentWriteFailure {
				throw failure
			} catch {
				throw .notSaved
			}
			pendingModelChoice = nil
		}
		consentContext = nil
	}

	func declineConsent(_ challenge: ConsentChallenge) {
		if pendingModelChoice?.challenge == challenge { pendingModelChoice = nil }
	}

	private func creditsEntry(_ model: ModelID) throws -> ModelCatalogEntry {
		let details = catalog.entries[model] ?? ModelCatalog.bundled.entries[model]
		return try catalog.choice(model, retaining: details)
	}

	func requestTarget(_ request: CompletionRequest) throws(AccessUnavailable) -> ConsentTarget {
		do {
			let entry: ModelCatalogEntry
			if let provider = request.provider {
				let details = try ModelDetails(
					displayName: request.model.rawValue, provider: provider)
				entry = try catalog.choice(request.model, retaining: details)
			} else {
				entry = try creditsEntry(request.model)
			}
			return ConsentTarget(method: request.credential.method, entry: entry)
		} catch {
			throw .malformedStoredCredential(.accessSelection)
		}
	}
}
