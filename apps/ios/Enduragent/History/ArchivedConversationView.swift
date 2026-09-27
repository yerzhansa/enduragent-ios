import EnduragentCoach
import SwiftUI

struct ArchivedConversationView: View {
	var model: ShellModel
	var conversation: ArchivedConversation

	var body: some View {
		VStack(spacing: 0) {
			List(conversation.turns) { turn in
				VStack(alignment: .leading, spacing: 8) {
					if let athleteText = turn.athleteText {
						Text(athleteText)
					}
					reply(turn.state)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.listRowSeparator(.hidden)
			}
			.listStyle(.plain)
			Text(say(Catalog.archiveReadOnly))
				.font(.footnote)
				.foregroundStyle(.secondary)
				.padding()
				.accessibilityIdentifier("archive.readOnly")
		}
		.navigationTitle(say(Catalog.archiveConversation))
	}

	@ViewBuilder
	private func reply(_ state: TurnState) -> some View {
		switch state {
		case .completed(let completed):
			switch completed.reply {
			case .model(let text):
				Text(text)
			}
		case .interrupted(let interrupted):
			if !interrupted.partial.isEmpty {
				Text(interrupted.partial)
					.foregroundStyle(.secondary)
			}
			notice(interrupted.notice)
		case .savedWork(let savedWork):
			notice(savedWork.notice)
		case .failed(let failed):
			notice(failed.notice)
		case .unrecovered(let unrecovered):
			notice(unrecovered.notice)
		case .accepted, .processing:
			EmptyView()
		}
	}

	private func notice(_ notice: AthleteNotice) -> some View {
		Text(notice.sentence(in: model.builder.phrasebook))
			.foregroundStyle(.secondary)
	}

	private func say(_ key: CatalogKey) -> String {
		model.builder.phrasebook.say(key, [:])
	}
}
