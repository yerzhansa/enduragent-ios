import EnduragentCoach
import SwiftUI

struct TranscriptView: View {
	@Bindable var model: ShellModel

	var body: some View {
		ScrollViewReader { proxy in
			List {
				Group {
					if let opening = model.chat?.opening, opening != .continuing {
						Text(
							Welcome.text(
								in: model.builder.phrasebook, showsSyncLine: model.connected != nil)
						)
						.accessibilityIdentifier("chat.welcome")
						if let notice = opening.notice {
							newConversationNotice(notice)
						}
					}
					ForEach(model.chat?.turns ?? []) { turn in
						TurnRowView(model: model, turn: turn)
					}
					if case .startingNewConversation(let label)? = model.chat?.activity {
						Text(model.builder.phrasebook.say(label, [:]))
							.foregroundStyle(.secondary)
							.accessibilityIdentifier("chat.working")
					}
					if model.newConversationUncertain {
						newConversationNotice(Catalog.chatNoticeNewConversationUncertain)
					}
					if let confirmLine = model.confirmLine {
						Text(confirmLine)
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

	private func newConversationNotice(_ key: CatalogKey) -> some View {
		Text(model.builder.phrasebook.say(key, [:]))
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("chat.newConversation.notice")
	}
}
