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
			let key = try persistedOpenRouterKey(at: reference.credential)
			return ResolvedAccess(
				credential: ProviderCredential(
					secret: key.value.secret.value, method: .openRouterAccount),
				model: reference.model)
		}
	}

	package func accessStatus(builtInModel: ModelID) -> AccessStatus {
		let state: AccessState
		do {
			let saved = try keychain(.accessSelection) { try store.accessSelection() }
			state = accessState(for: saved)
		} catch {
			state = .unreadable(error)
		}
		return AccessStatus(state: state, builtInModel: builtInModel)
	}

	package func change(_ change: ModelAccessChange, builtInModel: ModelID)
		-> CredentialOutcome<AccessSummary>
	{
		let previous: AccessSummary?
		let saved: SavedAccessReference?
		do {
			saved = try keychain(.accessSelection) { try store.accessSelection() }
			previous = AccessStatus(state: accessState(for: saved), builtInModel: builtInModel)
				.selection.map { AccessSummary(selection: $0) }
		} catch {
			return .failedPreviousKept(.secureStorage(error), previous: nil)
		}
		do throws(AccessUnavailable) {
			switch change {
			case .keep:
				return .kept(previous)
			case .useCredits:
				guard try persistedCreditsKey() != nil else {
					throw AccessUnavailable.notConfigured(.credits)
				}
				try keychain(.accessSelection) { try store.storeAccessSelection(.init(.credits)) }
				return .replaced(AccessSummary(selection: .credits), authority: nil)
			case .signInToOpenRouter:
				return .failedPreviousKept(.signIn(.presentationUnavailable), previous: previous)
			case .selectOpenRouterModel:
				return .refused(.modelNotInCatalog)
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
				return .openRouter(OpenRouterChoice(credential: key, model: reference.model))
			} catch {
				return .unresolvedOpenRouter(reference, error)
			}
		}
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
