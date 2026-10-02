import EnduragentCoach
import SwiftUI

enum HistoryList: Equatable {
	case loading
	case loaded([ArchivedConversationSummary])
	case unavailable
}

struct HistoryView: View {
	var model: ShellModel

	var body: some View {
		Group {
			switch model.history {
			case .loading:
				ProgressView()
			case .unavailable:
				Text(say(Catalog.archiveListFailure))
			case .loaded(let conversations) where conversations.isEmpty:
				Text(say(Catalog.archiveEmpty))
			case .loaded(let conversations):
				List(conversations) { conversation in
					NavigationLink(value: ShellDestination.archivedConversation(conversation.id)) {
						row(conversation)
					}
					.accessibilityIdentifier("history.row.\(conversation.id.rawValue)")
				}
			}
		}
		.navigationTitle(say(Catalog.archiveHistory))
		.task {
			await model.loadHistory()
		}
	}

	private func row(_ conversation: ArchivedConversationSummary) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			if let question = conversation.firstQuestion {
				Text(question)
					.lineLimit(2)
			}
			Text(say(conversation.reason.title))
				.font(.footnote)
			Text(conversation.startedOn.rawValue)
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
	}

	private func say(_ key: CatalogKey) -> String {
		model.phrasebook.say(key, [:])
	}
}
