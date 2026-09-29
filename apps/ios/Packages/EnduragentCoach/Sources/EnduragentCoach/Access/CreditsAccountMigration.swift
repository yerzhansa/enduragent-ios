import Foundation

func restoredCreditsAccount(
	current: CreditsAccount?,
	undo: @autoclosure () throws -> LegacyCreditsUndo?,
	legacyKey: @autoclosure () throws -> String?,
	legacyToken: @autoclosure () throws -> UUID?
) rethrows -> CreditsAccount? {
	if let current { return current }
	if let previous = try undo()?.credits {
		return CreditsAccount(
			appAccountToken: previous.previousAppAccountToken, key: previous.previousKey)
	}
	let key = try legacyKey()
	guard let token = try legacyToken() else { return nil }
	return CreditsAccount(appAccountToken: token, key: key)
}

struct LegacyCreditsUndo: Decodable {
	struct Credits: Decodable {
		let previousKey: String?
		let previousAppAccountToken: UUID
	}

	let credits: Credits?
}
