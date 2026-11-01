import EnduragentCoach
import Foundation

@MainActor
final class DraftStore {
	private static let prefix = "enduragent.draft."
	private let defaults: UserDefaults

	init(defaults: UserDefaults) {
		self.defaults = defaults
	}

	func load(_ chat: ChatID) -> Draft? {
		guard let text = defaults.string(forKey: textKey(chat)), !text.isEmpty,
			let raw = defaults.string(forKey: idKey(chat)), let id = UUID(uuidString: raw)
		else {
			return nil
		}
		return Draft(id: DraftID(rawValue: id), text: text)
	}

	func save(_ draft: Draft, for chat: ChatID) {
		if draft.text.isEmpty {
			clear(chat)
			return
		}
		defaults.set(draft.id.rawValue.uuidString, forKey: idKey(chat))
		defaults.set(draft.text, forKey: textKey(chat))
	}

	func clear(_ chat: ChatID) {
		defaults.removeObject(forKey: idKey(chat))
		defaults.removeObject(forKey: textKey(chat))
	}

	private func idKey(_ chat: ChatID) -> String {
		Self.prefix + chat.rawValue + ".id"
	}

	private func textKey(_ chat: ChatID) -> String {
		Self.prefix + chat.rawValue + ".text"
	}
}
