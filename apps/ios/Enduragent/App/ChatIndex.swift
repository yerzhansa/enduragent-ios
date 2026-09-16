import EnduragentCoach
import Foundation

struct ChatIndexEntry: Codable, Equatable {
	var id: String
	var created: String
}

@MainActor
final class ChatIndex {
	private static let defaultsKey = "enduragent.chatIndex"
	private let isFixture: Bool
	private let defaults: UserDefaults
	private var entries: [ChatIndexEntry]

	init(isFixture: Bool, defaults: UserDefaults = .standard) {
		self.isFixture = isFixture
		self.defaults = defaults
		if isFixture {
			entries = []
			return
		}
		if let data = defaults.data(forKey: Self.defaultsKey),
			let decoded = try? JSONDecoder().decode([ChatIndexEntry].self, from: data)
		{
			entries = decoded
		} else {
			entries = []
		}
	}

	func all() -> [ChatIndexEntry] {
		entries
	}

	func add(id: ChatID, created: CivilDate) {
		guard !entries.contains(where: { $0.id == id.rawValue }) else { return }
		entries.insert(ChatIndexEntry(id: id.rawValue, created: created.rawValue), at: 0)
		if isFixture { return }
		if let data = try? JSONEncoder().encode(entries) {
			defaults.set(data, forKey: Self.defaultsKey)
		}
	}
}
