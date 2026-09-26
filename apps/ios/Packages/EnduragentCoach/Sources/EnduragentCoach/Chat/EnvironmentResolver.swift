import Foundation

package struct EnvironmentResolver: Sendable {
	package let language: @Sendable () async -> LanguagePreference
	package let access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess
	package let training: @Sendable () async throws(AccessUnavailable) -> TrainingConnection

	package init(
		language: @escaping @Sendable () async -> LanguagePreference,
		access: @escaping @Sendable () async throws(AccessUnavailable) -> ResolvedAccess,
		training: @escaping @Sendable () async throws(AccessUnavailable) -> TrainingConnection
	) {
		self.language = language
		self.access = access
		self.training = training
	}

	package func attempt(
		of facts: TurnFacts, attempt: AttemptID, chat: ChatID, in resolved: AttemptEnvironment
	) async -> TurnAttempt {
		TurnAttempt(
			turn: facts.turn, attempt: attempt, chat: chat, request: facts.requestText,
			slash: facts.slash, language: await language(), access: resolved.access,
			training: resolved.training)
	}

	package func resolve() async -> Result<AttemptEnvironment, AccessUnavailable> {
		do {
			return .success(
				AttemptEnvironment(access: try await access(), training: try await training()))
		} catch {
			return .failure(error)
		}
	}
}

package struct AttemptEnvironment: Sendable {
	package let access: ResolvedAccess
	package let training: TrainingConnection
}

extension Result where Success == AttemptEnvironment {
	package var account: TrainingAccount {
		switch self {
		case .success(let environment): environment.training.account
		case .failure: .unconnected
		}
	}
}
