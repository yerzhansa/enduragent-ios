import Foundation

struct RejectedOpenRouterKeyPayload: Codable {
	let generation: UUID?

	init(_ reference: OpenRouterCredentialRef) {
		switch reference {
		case .legacy: generation = nil
		case .generation(let id): generation = id
		}
	}

	var reference: OpenRouterCredentialRef {
		generation.map(OpenRouterCredentialRef.generation) ?? .legacy
	}
}
