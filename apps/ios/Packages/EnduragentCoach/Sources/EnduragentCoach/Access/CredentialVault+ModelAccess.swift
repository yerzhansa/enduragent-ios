import Foundation

package struct Persisted<Value: Equatable & Sendable>: Equatable, Sendable {
	let value: Value

	fileprivate init(_ value: Value) {
		self.value = value
	}
}

extension CredentialVault {
	package func modelAccess(builtInModel: ModelID) throws(AccessUnavailable) -> ResolvedAccess {
		let saved = try keychain(.accessSelection) { try store.accessSelection() }
		switch saved?.value {
		case nil, .credits?:
			guard let key = try persistedCreditsKey() else { throw .notConfigured(.credits) }
			return ResolvedAccess(
				credential: ProviderCredential(secret: key.value.secret.value, method: .credits),
				model: builtInModel)
		case .openRouter(let reference)?:
			try authorizeOpenRouterKey(reference.credential)
			let key = try persistedOpenRouterKey(at: reference.credential)
			let entry = try savedEntry(reference)
			return ResolvedAccess(
				credential: ProviderCredential(
					secret: key.value.secret.value, method: .openRouterAccount,
					openRouterReference: reference.credential),
				model: entry.id, provider: entry.details.provider)
		}
	}

	package func accessStatus(builtInModel: ModelID, consent: ProviderConsent? = nil)
		-> AccessStatus
	{
		let state: AccessState
		do {
			let saved = try keychain(.accessSelection) { try store.accessSelection() }
			state = accessState(for: saved)
		} catch {
			state = .unreadable(error)
		}
		return AccessStatus(
			state: state, builtInModel: builtInModel, catalog: catalog,
			consent: accessConsent(builtInModel: builtInModel, recorded: consent))
	}

	package func change(
		_ change: ModelAccessChange, builtInModel: ModelID, consent: ProviderConsent? = nil
	)
		async -> CredentialOutcome<AccessSummary>
	{
		if change == .signInToOpenRouter { return await signIn(builtInModel: builtInModel) }
		if change != .keep {
			signInFlight = nil
			pendingModelChoice = nil
			consentContext = nil
		}
		let previous: AccessSummary?
		let saved: SavedAccessReference?
		do {
			saved = try keychain(.accessSelection) { try store.accessSelection() }
			previous = AccessStatus(
				state: accessState(for: saved), builtInModel: builtInModel, catalog: catalog
			)
			.selection.map { AccessSummary(selection: $0) }
		} catch {
			return .failedPreviousKept(.secureStorage(error), previous: nil)
		}
		do throws(AccessUnavailable) {
			switch change {
			case .keep, .signInToOpenRouter:
				return .kept(previous)
			case .useCredits:
				guard try persistedCreditsKey() != nil else {
					throw AccessUnavailable.notConfigured(.credits)
				}
				try keychain(.accessSelection) { try store.storeAccessSelection(.init(.credits)) }
				return .replaced(AccessSummary(selection: .credits), authority: nil)
			case .selectOpenRouterModel(let id):
				let entry: ModelCatalogEntry
				do {
					entry = try catalog.choice(id)
				} catch {
					return .refused(.modelNotInCatalog)
				}
				guard case .openRouter(let reference) = saved?.value else {
					throw AccessUnavailable.notConfigured(.openRouterAccount)
				}
				let key = try persistedOpenRouterKey(at: reference.credential)
				let choice = OpenRouterChoice(credential: key, entry: entry)
				let target = ConsentTarget(method: .openRouterAccount, entry: entry)
				if consent?.authorizes(target) != true {
					pendingModelChoice = ConsentContext(
						base: saved, challenge: ConsentChallenge(target: target, generation: UUID())
					)
					return .kept(previous)
				}
				try keychain(.accessSelection) {
					try store.storeAccessSelection(
						.init(
							.openRouter(
								SavedOpenRouterReference(
									credential: choice.credential, model: choice.model,
									details: entry.details))))
				}
				return .replaced(
					AccessSummary(selection: .openRouterAccount(choice)), authority: nil)
			case .disconnectOpenRouter:
				let reference: OpenRouterCredentialRef
				if case .openRouter(let selected) = saved?.value {
					reference = selected.credential
				} else {
					reference = .legacy
				}
				try keychain(.openRouterAccountKey) {
					try store.deleteOpenRouterAccountKey(at: reference)
				}
				return .disconnected
			}
		} catch {
			return .failedPreviousKept(.secureStorage(error), previous: previous)
		}
	}

	private func accessState(for saved: SavedAccessReference?) -> AccessState {
		switch saved?.value {
		case nil, .credits?:
			let availability: AccessAvailability
			do {
				availability = try persistedCreditsKey() == nil ? .needsSetup : .ready
			} catch {
				availability = .unavailable(error)
			}
			return saved == nil ? .defaultCredits(availability) : .credits(availability)
		case .openRouter(let reference)?:
			do {
				let key = try persistedOpenRouterKey(at: reference.credential)
				if let rejectionReadFailure { return .unreadable(rejectionReadFailure) }
				let choice = OpenRouterChoice(credential: key, entry: try savedEntry(reference))
				return rejectedKeys.contains(reference.credential)
					? .rejectedOpenRouter(choice) : .openRouter(choice)
			} catch {
				return .unresolvedOpenRouter(reference, error)
			}
		}
	}

	func savedEntry(_ reference: SavedOpenRouterReference) throws(AccessUnavailable)
		-> ModelCatalogEntry
	{
		do {
			return try catalog.choice(reference.model, retaining: reference.details)
		} catch {
			throw .malformedStoredCredential(.accessSelection)
		}
	}

	func stageOpenRouterKey(_ key: NonEmptySecret, at reference: OpenRouterCredentialRef)
		throws(AccessUnavailable) -> Persisted<OpenRouterAccountKey>
	{
		try keychain(.openRouterAccountKey) {
			try store.storeOpenRouterAccountKey(key.value, at: reference)
		}
		return Persisted(OpenRouterAccountKey(reference: reference, secret: key))
	}

	private func persistedCreditsKey() throws(AccessUnavailable) -> Persisted<CreditsKey>? {
		try creditsKey().map { Persisted(CreditsKey(secret: $0)) }
	}

	private func persistedOpenRouterKey(at reference: OpenRouterCredentialRef)
		throws(AccessUnavailable) -> Persisted<OpenRouterAccountKey>
	{
		guard
			let key = try keychain(
				.openRouterAccountKey,
				{
					try store.openRouterAccountKey(at: reference)
				}
			).flatMap(NonEmptySecret.init)
		else { throw .notConfigured(.openRouterAccount) }
		return Persisted(OpenRouterAccountKey(reference: reference, secret: key))
	}
}
