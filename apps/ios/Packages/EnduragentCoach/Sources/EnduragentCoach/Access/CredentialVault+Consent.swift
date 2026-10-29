import Foundation

struct ConsentContext: Sendable {
	let base: SavedAccessReference?
	let challenge: ConsentChallenge
}

struct ConsentSelectionChange: Sendable {
	let previous: SavedAccessReference
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
			return ConsentTarget(method: .credits, entry: try builtInEntry(builtInModel))
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

	func prepareConsentSelection(_ challenge: ConsentChallenge, builtInModel: ModelID)
		throws(ConsentWriteFailure) -> ConsentSelectionChange?
	{
		try validateConsent(challenge, builtInModel: builtInModel)
		var selection: ConsentSelectionChange?
		if let pending = pendingModelChoice {
			do {
				guard let previous = pending.base, case .openRouter(let reference) = previous.value
				else {
					throw ConsentWriteFailure.staleChallenge
				}
				let saved = SavedAccessReference(
					.openRouter(
						SavedOpenRouterReference(
							credential: reference.credential,
							model: challenge.target.entry.id,
							details: challenge.target.entry.details)),
					consentCommit: challenge.generation)
				try keychain(.accessSelection) {
					try store.prepareAccessSelection(saved, at: challenge.generation)
				}
				selection = ConsentSelectionChange(
					previous: previous, challenge: challenge)
			} catch let failure as ConsentWriteFailure {
				throw failure
			} catch {
				throw .notSaved
			}
		}
		return selection
	}

	func finishConsent(_ challenge: ConsentChallenge) {
		if pendingModelChoice?.challenge == challenge { pendingModelChoice = nil }
		if consentContext?.challenge == challenge { consentContext = nil }
	}

	func commitConsentSelection(_ selection: ConsentSelectionChange) throws(ConsentWriteFailure) {
		do {
			let saved = try keychain(.accessSelection) { try store.accessSelection() }
			guard saved == selection.previous, pendingModelChoice?.challenge == selection.challenge
			else {
				throw ConsentWriteFailure.staleChallenge
			}
			try keychain(.accessSelection) {
				try store.commitAccessSelection(at: selection.challenge.generation)
			}
		} catch let failure as ConsentWriteFailure {
			throw failure
		} catch {
			throw .notSaved
		}
	}

	func recordedConsent(_ records: [ProviderConsent]) throws(AccessUnavailable) -> ProviderConsent?
	{
		let saved = try keychain(.accessSelection) { try store.accessSelection() }
		return records.last {
			$0.selectionCommit == nil || $0.selectionCommit == saved?.consentCommit
		}
	}

	func declineConsent(_ challenge: ConsentChallenge) {
		if pendingModelChoice?.challenge == challenge { pendingModelChoice = nil }
	}

	func requestTarget(_ request: CompletionRequest) throws(AccessUnavailable) -> ConsentTarget {
		do {
			let entry = try ModelCatalogEntry(
				id: request.model,
				details: ModelDetails(
					displayName: request.model.rawValue, provider: request.provider))
			return ConsentTarget(method: request.credential.method, entry: entry)
		} catch {
			throw .malformedStoredCredential(.accessSelection)
		}
	}
}
