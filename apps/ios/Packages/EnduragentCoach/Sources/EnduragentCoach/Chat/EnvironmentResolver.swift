import Foundation

package struct EnvironmentResolver: Sendable {
	package let preferences: @Sendable () async -> Preferences
	package let access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess
	package let training: @Sendable () async throws(AccessUnavailable) -> TrainingConnection
	package let deviceLanguage: LanguageTag

	package init(
		preferences: @escaping @Sendable () async -> Preferences,
		access: @escaping @Sendable () async throws(AccessUnavailable) -> ResolvedAccess,
		training: @escaping @Sendable () async throws(AccessUnavailable) -> TrainingConnection,
		deviceLanguage: LanguageTag
	) {
		self.preferences = preferences
		self.access = access
		self.training = training
		self.deviceLanguage = deviceLanguage
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
			language: resolved.preferences.language.replyLanguage(
				for: facts.requestText, device: deviceLanguage),
			session: resolved.preferences.session, access: resolved.access,
			training: resolved.training, process: process)
	}

	package func resolve() async -> Result<AttemptEnvironment, AccessUnavailable> {
		let preferences = await preferences()
		do {
			return .success(
				AttemptEnvironment(
					access: try await access(), training: try await training(),
					preferences: preferences))
		} catch {
			return .failure(error)
		}
	}

	package func appLanguage() async -> LanguageTag {
		await preferences().language.appLanguage(device: deviceLanguage)
	}

	package func flushAccess() async
		-> @Sendable () async throws(AccessUnavailable) -> ResolvedAccess
	{
		let session = await preferences().session
		let access = self.access
		return { () async throws(AccessUnavailable) in
			let resolved = try await access()
			return resolved.using(
				model: ModelRoles(response: resolved.model, session: session).flush)
		}
	}
}

package struct AttemptEnvironment: Sendable {
	package let access: ResolvedAccess
	package let training: TrainingConnection
	package let preferences: Preferences
}

extension Result where Success == AttemptEnvironment {
	package var account: TrainingAccount {
		switch self {
		case .success(let environment): environment.training.account
		case .failure: .unconnected
		}
	}
}
