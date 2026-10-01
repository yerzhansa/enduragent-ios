import EnduragentCoach
import SwiftUI

struct TranscriptView: View {
	@Bindable var model: ShellModel
	@Environment(\.scenePhase) private var scenePhase

	var body: some View {
		ScrollViewReader { proxy in
			List {
				Group {
					if let opening = model.chat?.opening {
						if opening.showsWelcome {
							Text(Welcome.text(in: model.phrasebook))
								.accessibilityIdentifier("chat.welcome")
						}
						if let notice = opening.notice {
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
					if let review = model.chat?.review {
						ConfirmedPreviewCard(model: model, review: review)
							.fixedSize(horizontal: false, vertical: true)
					}
					if let notice = model.reviewNotice {
						Text(notice.sentence(in: model.phrasebook))
							.accessibilityIdentifier("chat.review.notice")
					}
				}
				.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
				.listRowSeparator(.hidden)
				.listRowBackground(Color.clear)
				if model.slashListVisible {
					SlashListView(model: model)
						.listRowInsets(EdgeInsets())
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)
				}
				Color.clear
					.frame(height: 1)
					.listRowInsets(EdgeInsets())
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
					.id("transcript.tail")
			}
			.listStyle(.plain)
			.accessibilityIdentifier("chat.transcript")
			.environment(\.defaultMinListRowHeight, 0)
			.buttonStyle(.borderless)
			.onChange(of: model.chat?.revision, initial: true) {
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
			.onChange(of: scenePhase) { _, phase in
				guard phase == .active, model.chat?.turns.last?.completedInBackground == true else {
					return
				}
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
			.onChange(of: model.slashListVisible) {
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
			.onChange(of: model.reviewNotice) {
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
			.onReceive(
				NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)
			) { _ in
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
		}
	}

	private func notes(after turn: TurnID?) -> some View {
		ForEach(model.chat?.notes[turn] ?? []) { note in
			Text(note.sentence(in: model.phrasebook))
				.accessibilityIdentifier("chat.note")
		}
	}

	private func newConversationNotice(_ key: CatalogKey) -> some View {
		Text(model.phrasebook.say(key, [:]))
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("chat.newConversation.notice")
	}
}
