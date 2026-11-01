import EnduragentCoach
import SwiftUI

struct TranscriptView: View {
	@Bindable var model: ShellModel
	@Environment(\.scenePhase) private var scenePhase
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@State private var revealedBackgroundTurns: Set<TurnID> = []
	@State private var openedReview: String?
	@State private var openedPlan: PlanConfirmationID?
	@State private var viewport = TranscriptViewport(frame: .null)

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
					reviewCard(at: .preparedEarlier, proxy: proxy)
					planCards(at: .preparedEarlier)
					notes(after: nil)
					ForEach(model.chat?.turns ?? []) { turn in
						TurnRowView(model: model, turn: turn)
						notes(after: turn.id)
						reviewCard(at: .afterTurn(turn.id), proxy: proxy)
						planCards(at: .afterTurn(turn.id))
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
					if ChromePlacement(dynamicTypeSize) == .inTranscript {
						ChatDisclaimer(model: model)
							.fixedSize(horizontal: false, vertical: true)
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
			.onGeometryChange(for: CGRect.self) {
				$0.frame(in: .global)
			} action: {
				viewport = TranscriptViewport(frame: $0)
			}
			.accessibilityIdentifier("chat.transcript")
			.environment(\.defaultMinListRowHeight, 0)
			.environment(\.transcriptViewport, viewport)
			.buttonStyle(.borderless)
			.onChange(of: model.chat?.revision, initial: true) {
				if waitingPlanEndingTranscript != nil || reviewEndsTranscript {
					reveal()
				} else {
					scrollToEnd(proxy)
				}
			}
			.onChange(of: openingPlan?.id, initial: true) {
				aimAtOpeningPlan(proxy)
			}
			.onScrollGeometryChange(for: CGFloat.self) {
				$0.contentSize.height
			} action: { _, _ in
				aimAtOpeningPlan(proxy)
			}
			.onScrollPhaseChange { _, phase in
				if phase == .interacting { endOpening() }
			}
			.onChange(of: shownRound, initial: true) { old, new in
				guard let new else { return }
				if let old, old.title == new.title, old.round != new.round {
					proxy.scrollTo(new.title, anchor: .top)
				} else if let review = model.chat?.review {
					approachReview(review, proxy)
				}
			}
			.onChange(of: scenePhase) { _, phase in
				guard phase == .active, let turn = model.chat?.turns.last,
					turn.completedInBackground, !revealedBackgroundTurns.contains(turn.id)
				else { return }
				scrollToEnd(proxy)
			}
			.onChange(of: model.slashListVisible) {
				scrollToTail(proxy)
			}
			.onChange(of: model.status.access.attention) {
				scrollToTail(proxy)
			}
			.onChange(of: model.reviewNotice) {
				scrollToTail(proxy)
			}
			.onReceive(
				NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)
			) { _ in
				scrollToTail(proxy)
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

	private var waitingPlanEndingTranscript: PlanCard? {
		guard let plan = model.chat?.plans.last, case .waiting = plan.state else { return nil }
		switch plan.placement {
		case .afterTurn(let turn): return turn == model.chat?.turns.last?.id ? plan : nil
		case .preparedEarlier: return model.chat?.turns.isEmpty ?? true ? plan : nil
		}
	}

	private var openingPlan: PlanCard? {
		guard let plan = waitingPlanEndingTranscript, plan.id != openedPlan else { return nil }
		return plan
	}

	private func aimAtOpeningPlan(_ proxy: ScrollViewProxy) {
		guard let plan = openingPlan else { return }
		proxy.scrollTo(PlanCardView.titleRow(of: plan), anchor: .center)
	}

	private func endOpening() {
		if let plan = openingPlan { openedPlan = plan.id }
	}

	private func approachReview(_ review: ReviewSnapshot, _ proxy: ScrollViewProxy) {
		let title = ConfirmedPreviewCard.titleRow(of: review)
		guard reviewEndsTranscript, openedReview != title else { return }
		proxy.scrollTo(title, anchor: .top)
	}

	private func openReview(_ review: ReviewSnapshot, _ proxy: ScrollViewProxy) {
		let title = ConfirmedPreviewCard.titleRow(of: review)
		guard reviewEndsTranscript, openedReview != title else { return }
		openedReview = title
		proxy.scrollTo(title, anchor: .top)
	}

	private func scrollToEnd(_ proxy: ScrollViewProxy) {
		scrollToTail(proxy)
		reveal()
	}

	private func scrollToTail(_ proxy: ScrollViewProxy) {
		endOpening()
		proxy.scrollTo("transcript.tail", anchor: .bottom)
	}

	private func reveal() {
		if scenePhase == .active {
			revealedBackgroundTurns.formUnion(
				(model.chat?.turns ?? []).filter(\.completedInBackground).map(\.id))
		}
	}

	private func notes(after turn: TurnID?) -> some View {
		ForEach(model.chat?.notes[turn] ?? []) { note in
			TranscriptNoteView(display: model.displayLocale, note: note)
		}
	}

	@ViewBuilder
	private func reviewCard(at placement: ReviewPlacement, proxy: ScrollViewProxy) -> some View {
		if let review = model.chat?.review, review.placement == placement {
			ConfirmedPreviewCard(
				model: model, review: review, round: model.reviewPresentation?.round ?? 0,
				titleLaidOut: { openReview(review, proxy) },
				cardLaidOut: { approachReview(review, proxy) }
			)
			.fixedSize(horizontal: false, vertical: true)
		}
	}

	private func planCards(at placement: PlanCardPlacement) -> some View {
		ForEach((model.chat?.plans ?? []).filter { $0.placement == placement }) { plan in
			PlanCardView(model: model, card: plan)
		}
	}

	private func newConversationNotice(_ key: CatalogKey) -> some View {
		Text(model.phrasebook.say(key, [:]))
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("chat.newConversation.notice")
	}
}

private struct TranscriptNoteView: View {
	var display: DisplayLocale
	var note: TranscriptNote

	var body: some View {
		let sentence = Text(note.sentence(in: display)).accessibilityIdentifier("chat.note")
		if let closing = note.closing(in: display) {
			VStack(alignment: .leading, spacing: 8) {
				sentence
				Text(closing)
					.font(.body.weight(.semibold))
					.accessibilityIdentifier("chat.note.closing")
			}
			.padding(12)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
			.accessibilityElement(children: .contain)
		} else {
			sentence
		}
	}
}

private struct ShownRound: Equatable {
	let title: String
	let round: Int
}
