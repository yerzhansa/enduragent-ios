import EnduragentCoach
import Observation

@MainActor
@Observable
final class HistoryModel {
	private(set) var list: HistoryList = .loading
	private let coach: Coach

	init(coach: Coach) {
		self.coach = coach
	}

	func load() async {
		do {
			list = .loaded(try await coach.history())
		} catch {
			switch error {
			case .storageUnavailable:
				list = .unavailable
			}
		}
	}

	func loadArchivedConversation(_ ref: ArchivedConversationRef) async
		-> ArchivedConversationContent
	{
		do {
			guard let conversation = try await coach.archivedConversation(ref) else {
				return .missing
			}
			return .loaded(conversation)
		} catch {
			return .unavailable
		}
	}
}
