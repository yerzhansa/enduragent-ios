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
	private(set) var loadError: Error?

	init(isFixture: Bool, defaults: UserDefaults = .standard) {
		self.isFixture = isFixture
		self.defaults = defaults
		if isFixture {
			entries = []
			return
		}
		if let data = defaults.data(forKey: Self.defaultsKey) {
			do {
				entries = try JSONDecoder().decode([ChatIndexEntry].self, from: data)
			} catch {
				entries = []
				loadError = error
			}
		} else {
			entries = []
		}
	}

	func all() -> [ChatIndexEntry] {
		entries
	}

	func add(id: ChatID, created: CivilDate) throws {
		guard !entries.contains(where: { $0.id == id.rawValue }) else { return }
		entries.insert(ChatIndexEntry(id: id.rawValue, created: created.rawValue), at: 0)
		if isFixture { return }
		let data = try JSONEncoder().encode(entries)
		defaults.set(data, forKey: Self.defaultsKey)
	}
}
