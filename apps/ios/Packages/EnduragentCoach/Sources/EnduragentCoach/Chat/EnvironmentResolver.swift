import Foundation

package struct EnvironmentResolver: Sendable {
	package let preferences: @Sendable () async -> Preferences
	package let access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess
	package let training: @Sendable () async throws(AccessUnavailable) -> TrainingConnection
	package let displayLocale: DisplayLocaleResolver

	package init(
		preferences: @escaping @Sendable () async -> Preferences,
		access: @escaping @Sendable () async throws(AccessUnavailable) -> ResolvedAccess,
		training: @escaping @Sendable () async throws(AccessUnavailable) -> TrainingConnection,
		displayLocale: @escaping DisplayLocaleResolver
	) {
		self.preferences = preferences
		self.access = access
		self.training = training
		self.displayLocale = displayLocale
	}

	package func attempt(
		of facts: TurnFacts, attempt: AttemptID, origin: AttemptOrigin, chat: ChatID,
		process: ProcessID,
		in resolved: AttemptEnvironment
	) -> TurnAttempt {
		TurnAttempt(
			turn: facts.turn, attempt: attempt, origin: origin, chat: chat,
			request: facts.requestText,
			slash: facts.slash,
			displayLocale: resolved.displayLocale,
			session: resolved.preferences.session, access: resolved.access,
			training: resolved.training, process: process)
	}

	package func resolve() async -> Result<AttemptEnvironment, AccessUnavailable> {
		let preferences = await preferences()
		let display = displayLocale(preferences.language)
		do {
			return .success(
				AttemptEnvironment(
					access: try await access(), training: try await training(),
					preferences: preferences, displayLocale: display))
		} catch {
			return .failure(error)
		}
	}

	package func appLanguage() async -> LanguageTag {
		displayLocale(await preferences().language).language
	}
}

package struct AttemptEnvironment: Sendable {
	package let access: ResolvedAccess
	package let training: TrainingConnection
	package let preferences: Preferences
	package let displayLocale: DisplayLocale
}

extension Result where Success == AttemptEnvironment {
	package var account: TrainingAccount {
		switch self {
		case .success(let environment): environment.training.account
		case .failure: .unconnected
		}
	}
}
