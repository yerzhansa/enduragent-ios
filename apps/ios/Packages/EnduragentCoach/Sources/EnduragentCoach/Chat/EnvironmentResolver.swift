import Foundation

package struct EnvironmentResolver: Sendable {
	package let preferences: @Sendable () async -> Preferences
	package let access: @Sendable () throws(AccessUnavailable) -> ResolvedAccess
	package let deviceLanguage: LanguageTag

	package init(
		preferences: @escaping @Sendable () async -> Preferences,
		access: @escaping @Sendable () throws(AccessUnavailable) -> ResolvedAccess,
		deviceLanguage: LanguageTag
	) {
		self.preferences = preferences
		self.access = access
		self.deviceLanguage = deviceLanguage
	}

	package func resolve() async -> Result<AttemptEnvironment, AccessUnavailable> {
		let preferences = await preferences()
		do {
			return .success(AttemptEnvironment(access: try access(), preferences: preferences))
		} catch {
			return .failure(error)
		}
	}

	package func attempt(
		of facts: TurnFacts, attempt: AttemptID, chat: ChatID, autoReset: ResetKind?,
		in environment: AttemptEnvironment
	) -> TurnAttempt {
		TurnAttempt(
			turn: facts.turn, attempt: attempt, chat: chat, request: facts.requestText,
			slash: facts.slash,
			language: environment.preferences.language.replyLanguage(
				for: facts.requestText, device: deviceLanguage),
			session: environment.preferences.session, access: environment.access,
			autoReset: autoReset)
	}

	package func flushAccess() async -> @Sendable () throws(AccessUnavailable) -> ResolvedAccess {
		let session = await preferences().session
		let access = self.access
		return { () throws(AccessUnavailable) in
			let resolved = try access()
			return resolved.using(
				model: ModelRoles(response: resolved.model, session: session).flush)
		}
	}
}

package struct AttemptEnvironment: Sendable {
	package let access: ResolvedAccess
	package let preferences: Preferences
}
