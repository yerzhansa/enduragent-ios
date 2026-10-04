import EnduragentCoach
import SwiftUI

struct TranscriptView: View {
	@Bindable var model: ShellModel
	@Environment(\.scenePhase) private var scenePhase
	@State private var revealedBackgroundTurns: Set<TurnID> = []

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
					if case .waiting? = model.chat?.reset {
						Text(model.phrasebook.say(Catalog.chatNoticeStartingNewConversation, [:]))
							.foregroundStyle(.secondary)
							.accessibilityIdentifier("chat.working")
					}
					if model.newConversationUncertain {
						newConversationNotice(Catalog.chatNoticeNewConversationUncertain)
					}
					if model.status.access.attention == .rejectedKey,
						let notice = model.status.access.notice
					{
						Text(notice.sentence(in: model.displayLocale))
							.accessibilityIdentifier("chat.access.notice")
						Button(model.phrasebook.say(Catalog.chatTurnSignInAgain)) {
							Task { await model.perform(.signInToOpenRouter) }
						}
						.disabled(model.isChangingAccess)
						.accessibilityIdentifier("chat.access.signInAgain")
						#if DEBUG
							FixtureSignInDebugView(model: model)
						#endif
						if let outcome = model.accessSettings.notice {
							Text(outcome.sentence(in: model.displayLocale))
								.accessibilityIdentifier("chat.access.outcome")
						}
					}
					if let review = model.chat?.review {
						ConfirmedPreviewCard(model: model, review: review)
							.fixedSize(horizontal: false, vertical: true)
					}
					if let notice = model.reviewNotice,
						model.chat?.review?.notice?.kind != .storageUnavailable
					{
						Text(notice.sentence(in: model.displayLocale))
							.accessibilityIdentifier("chat.review.notice")
						if let action = notice.action {
							Button(model.phrasebook.say(action.title)) {
								Task { await model.perform(action) }
							}
							.accessibilityIdentifier("chat.review.connect")
						}
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
				scrollToEnd(proxy)
			}
			.onChange(of: scenePhase) { _, phase in
				guard phase == .active, let turn = model.chat?.turns.last,
					turn.completedInBackground, !revealedBackgroundTurns.contains(turn.id)
				else { return }
				scrollToEnd(proxy)
			}
			.onChange(of: model.slashListVisible) {
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
			.onChange(of: model.status.access.attention) {
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

	private func scrollToEnd(_ proxy: ScrollViewProxy) {
		proxy.scrollTo("transcript.tail", anchor: .bottom)
		if scenePhase == .active {
			revealedBackgroundTurns.formUnion(
				(model.chat?.turns ?? []).filter(\.completedInBackground).map(\.id))
		}
	}

	private func notes(after turn: TurnID?) -> some View {
		ForEach(model.chat?.notes[turn] ?? []) { note in
			Text(note.sentence(in: model.displayLocale))
				.accessibilityIdentifier("chat.note")
		}
	}

	private func newConversationNotice(_ key: CatalogKey) -> some View {
		Text(model.phrasebook.say(key, [:]))
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("chat.newConversation.notice")
	}
}
