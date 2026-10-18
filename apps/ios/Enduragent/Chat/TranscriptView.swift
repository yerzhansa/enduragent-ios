import EnduragentCoach
import SwiftUI

struct TranscriptView: View {
	@Bindable var model: ShellModel
	@Environment(\.scenePhase) private var scenePhase
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@State private var revealedBackgroundTurns: Set<TurnID> = []
	@State private var openedReview: String?

	var body: some View {
		ScrollViewReader { proxy in
			List {
				Group {
					if ChromePlacement(dynamicTypeSize) == .inTranscript {
						ChatDisclaimer(model: model)
					}
					if let opening = model.chat?.opening {
						if opening.showsWelcome {
							Text(Welcome.text(in: model.phrasebook))
								.accessibilityIdentifier("chat.welcome")
						}
						if let notice = opening.notice {
							newConversationNotice(notice)
						}
					}
					reviewCard(at: .preparedEarlier, proxy: proxy)
					notes(after: nil)
					ForEach(model.chat?.turns ?? []) { turn in
						TurnRowView(model: model, turn: turn)
						notes(after: turn.id)
						reviewCard(at: .afterTurn(turn.id), proxy: proxy)
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
					if model.chat?.review == nil, let notice = model.reviewNotice {
						ReviewOutcomeNotice(model: model, notice: notice)
					}
				}
				.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
				.listRowSeparator(.hidden)
				.listRowBackground(Color.clear)
				.onAppear {
					openReview(proxy)
				}
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
				if reviewEndsTranscript {
					reveal()
				} else {
					scrollToEnd(proxy)
				}
			}
			.onChange(of: shownRound) { old, new in
				guard let old, let new, old.title == new.title, old.round != new.round else {
					return
				}
				proxy.scrollTo(new.title, anchor: .top)
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

	private var shownRound: ShownRound? {
		model.chat?.review.map { review in
			ShownRound(
				title: ConfirmedPreviewCard.titleRow(of: review),
				round: model.reviewPresentation?.round ?? 0)
		}
	}

	private var reviewEndsTranscript: Bool {
		guard let review = model.chat?.review else { return false }
		switch review.placement {
		case .afterTurn(let turn): return turn == model.chat?.turns.last?.id
		case .preparedEarlier: return model.chat?.turns.isEmpty ?? true
		}
	}

	private func openReview(_ proxy: ScrollViewProxy) {
		guard reviewEndsTranscript, let review = model.chat?.review else { return }
		let title = ConfirmedPreviewCard.titleRow(of: review)
		guard openedReview != title else { return }
		openedReview = title
		proxy.scrollTo(title, anchor: .top)
	}

	private func scrollToEnd(_ proxy: ScrollViewProxy) {
		proxy.scrollTo("transcript.tail", anchor: .bottom)
		reveal()
	}

	private func reveal() {
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

	@ViewBuilder
	private func reviewCard(at placement: ReviewPlacement, proxy: ScrollViewProxy) -> some View {
		if let review = model.chat?.review, review.placement == placement {
			ConfirmedPreviewCard(
				model: model, review: review, round: model.reviewPresentation?.round ?? 0
			)
			.fixedSize(horizontal: false, vertical: true)
			.onAppear {
				openReview(proxy)
			}
		}
	}

	private func newConversationNotice(_ key: CatalogKey) -> some View {
		Text(model.phrasebook.say(key, [:]))
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("chat.newConversation.notice")
	}
}

private struct ShownRound: Equatable {
	let title: String
	let round: Int
}
