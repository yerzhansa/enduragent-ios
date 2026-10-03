import Foundation

struct SignInFlight: Sendable {
	let generation: UUID
	let base: SavedAccessReference?
	let result: Task<CredentialOutcome<AccessSummary>, Never>
}

extension CredentialVault {
	func signIn(builtInModel: ModelID) async -> CredentialOutcome<AccessSummary> {
		if let flight = signInFlight { return await flight.result.value }
		let base: SavedAccessReference?
		do {
			base = try keychain(.accessSelection) { try store.accessSelection() }
		} catch {
			return .failedPreviousKept(.secureStorage(error), previous: nil)
		}
		let previous = accessStatus(builtInModel: builtInModel).selection.map {
			AccessSummary(selection: $0)
		}
		guard let service = signInService else {
			return .failedPreviousKept(.signIn(.presentationUnavailable), previous: previous)
		}
		let entry: ModelCatalogEntry
		do {
			if case .openRouter(let saved) = base?.value {
				entry = try savedEntry(saved)
			} else {
				entry = try catalog.choice(builtInModel)
			}
		} catch {
			return .failedPreviousKept(
				.secureStorage(.malformedStoredCredential(.accessSelection)), previous: previous)
		}
		let generation = UUID()
		let result = Task {
			await finishSignIn(
				service: service, generation: generation, entry: entry,
				previous: previous, builtInModel: builtInModel)
		}
		signInFlight = SignInFlight(generation: generation, base: base, result: result)
		let outcome = await result.value
		if signInFlight?.generation == generation { signInFlight = nil }
		return outcome
	}

	private func finishSignIn(
		service: OpenRouterSignInService, generation: UUID,
		entry: ModelCatalogEntry, previous: AccessSummary?, builtInModel: ModelID
	) async -> CredentialOutcome<AccessSummary> {
		let pkce = OpenRouterPKCE()
		do {
			let code: OpenRouterAuthCode
			do {
				code = try await service.authorizer.authorize(pkce.request)
			} catch {
				throw CredentialFailure.signIn(error)
			}
			guard try isCurrentSignIn(generation) else {
				return keptAccess(builtInModel: builtInModel)
			}
			let key = try await service.exchange.key(code, for: pkce)
			guard try isCurrentSignIn(generation) else {
				return keptAccess(builtInModel: builtInModel)
			}
			let persisted = try stageOpenRouterKey(key, at: .generation(generation))
			guard try isCurrentSignIn(generation) else {
				return keptAccess(builtInModel: builtInModel)
			}
			let choice = OpenRouterChoice(credential: persisted, entry: entry)
			try keychain(.accessSelection) {
				try store.storeAccessSelection(
					.init(
						.openRouter(
							SavedOpenRouterReference(
								credential: choice.credential, model: choice.model,
								details: entry.details))))
			}
			return .replaced(AccessSummary(selection: .openRouterAccount(choice)), authority: nil)
		} catch let failure as CredentialFailure {
			return .failedPreviousKept(failure, previous: previous)
		} catch let failure as AccessUnavailable {
			return .failedPreviousKept(.secureStorage(failure), previous: previous)
		} catch {
			return .failedPreviousKept(
				.secureStorage(.secureStorageUnavailable), previous: previous)
		}
	}

	private func isCurrentSignIn(_ generation: UUID)
		throws(AccessUnavailable) -> Bool
	{
		guard let flight = signInFlight, flight.generation == generation else { return false }
		return try keychain(.accessSelection) { try store.accessSelection() } == flight.base
	}

	private func keptAccess(builtInModel: ModelID) -> CredentialOutcome<AccessSummary> {
		.kept(
			accessStatus(builtInModel: builtInModel).selection.map { AccessSummary(selection: $0) })
	}
}
