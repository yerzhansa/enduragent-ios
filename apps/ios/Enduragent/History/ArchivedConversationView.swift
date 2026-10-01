import EnduragentCoach
import SwiftUI

enum ArchivedConversationContent: Equatable {
	case loading
	case loaded(ArchivedConversation)
	case missing
	case unavailable
}

struct ArchivedConversationView: View {
	var model: ShellModel
	let ref: ArchivedConversationRef
	@State private var content: ArchivedConversationContent = .loading

	var body: some View {
		Group {
			switch content {
			case .loading:
				ProgressView()
			case .loaded(let conversation):
				archive(conversation)
			case .missing:
				Text(say(Catalog.archiveUnavailable))
			case .unavailable:
				Text(say(Catalog.archivePageFailure))
			}
		}
		.navigationTitle(say(Catalog.archiveConversation))
		.task(id: ref) {
			content = await model.loadArchivedConversation(ref)
		}
	}

	private func archive(_ conversation: ArchivedConversation) -> some View {
		VStack(spacing: 0) {
			List {
				notes(conversation.notes, after: nil)
				ForEach(conversation.turns) { turn in
					VStack(alignment: .leading, spacing: 8) {
						if let athleteText = turn.athleteText {
							Text(athleteText)
						}
						reply(turn.state)
						notes(conversation.notes, after: turn.id)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.listRowSeparator(.hidden)
				}
			}
			.listStyle(.plain)
			Text(say(Catalog.archiveReadOnly))
				.font(.footnote)
				.foregroundStyle(.secondary)
				.padding()
				.accessibilityIdentifier("archive.readOnly")
		}
	}

	private func notes(_ notes: [TranscriptNote], after turn: TurnID?) -> some View {
		ForEach(notes.filter { $0.after == turn }) { note in
			Text(note.sentence(in: model.phrasebook))
				.accessibilityIdentifier("archive.note")
		}
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
		Text(notice.sentence(in: model.phrasebook))
			.foregroundStyle(.secondary)
	}

	private func say(_ key: CatalogKey) -> String {
		model.phrasebook.say(key, [:])
	}
}
