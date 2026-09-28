import EnduragentCoach
import SwiftUI

struct TranscriptView: View {
	@Bindable var model: ShellModel

	var body: some View {
		ScrollViewReader { proxy in
			List {
				Group {
					if let opening = model.chat?.opening {
						if opening.showsWelcome {
							Text(
								Welcome.text(
									in: model.phrasebook, showsSyncLine: model.connected != nil)
							)
							.accessibilityIdentifier("chat.welcome")
						}
						if case .afterAutomaticReset = opening, let notice = opening.notice {
							Text(model.phrasebook.say(notice, [:]))
								.foregroundStyle(.secondary)
								.accessibilityIdentifier("chat.automaticReset.notice")
						} else if let notice = opening.notice {
							newConversationNotice(notice)
						}
					}
					notes(after: nil)
					ForEach(model.chat?.turns ?? []) { turn in
						TurnRowView(model: model, turn: turn)
						notes(after: turn.id)
					}
					if case .startingNewConversation(let label)? = model.chat?.activity {
						Text(model.phrasebook.say(label, [:]))
							.foregroundStyle(.secondary)
							.accessibilityIdentifier("chat.working")
					}
					if model.newConversationUncertain {
						newConversationNotice(Catalog.chatNoticeNewConversationUncertain)
					}
				}
				.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
				.listRowSeparator(.hidden)
				.listRowBackground(Color.clear)
				Color.clear
					.frame(height: 1)
					.listRowInsets(EdgeInsets())
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
					.id("transcript.tail")
			}
			.listStyle(.plain)
			.environment(\.defaultMinListRowHeight, 0)
			.buttonStyle(.borderless)
			.onChange(of: model.chat) {
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
		}
	}

	private func notes(after turn: TurnID?) -> some View {
		ForEach((model.chat?.notes ?? []).filter { $0.after == turn }) { note in
			Text(note.notice.sentence(in: model.phrasebook))
				.accessibilityIdentifier("chat.note")
		}
	}

	private func newConversationNotice(_ key: CatalogKey) -> some View {
		Text(model.phrasebook.say(key, [:]))
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("chat.newConversation.notice")
	}
}
