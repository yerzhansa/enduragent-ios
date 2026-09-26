import EnduragentCoach
import SwiftUI

struct TurnRowView: View {
	var model: ShellModel
	var turn: TurnView

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(turn.athleteText)
			switch turn.state {
			case .accepted(.awaitingRestart):
				Text(say(Catalog.chatTurnReceivedBeforeClose))
					.accessibilityIdentifier("chat.turn.receivedBeforeClose")
				actionButton(.tryAgain(turn.id))
			case .accepted(.onOtherDevice):
				EmptyView()
			case .accepted(.collecting), .accepted(.queued):
				working
			case .processing(let processing):
				if !processing.liveText.isEmpty {
					Text(processing.liveText)
				}
				working
			case .completed(let completed):
				switch completed.reply {
				case .model(let text):
					Text(text)
				}
			case .savedWork(let savedWork):
				notice(savedWork.notice)
			case .failed(let failed):
				notice(failed.notice)
			case .interrupted(let interrupted):
				if !interrupted.partial.isEmpty {
					Text(interrupted.partial)
						.foregroundStyle(.secondary)
				}
				notice(interrupted.notice)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var working: some View {
		Text(say(Catalog.chatNoticeWorking))
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("chat.working")
	}

	private func notice(_ notice: AthleteNotice) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(notice.sentence(in: model.builder.phrasebook))
				.accessibilityIdentifier("chat.turn.notice")
			if let action = notice.action {
				actionButton(action)
			}
		}
	}

	@ViewBuilder
	private func actionButton(_ action: RecoveryAction) -> some View {
		if let opensAt = action.opensAt {
			TimelineView(.explicit([opensAt])) { _ in
				button(for: action)
					.disabled(Date.now < opensAt)
			}
		} else {
			button(for: action)
		}
	}

	private func button(for action: RecoveryAction) -> some View {
		Button(say(action.title)) {
			Task { await model.perform(action) }
		}
		.accessibilityIdentifier(identifier(for: action))
	}

	private func identifier(for action: RecoveryAction) -> String {
		switch action {
		case .tryAgain, .wait: "chat.turn.tryAgain"
		case .restoreCredits: "chat.turn.restorePurchases"
		case .buyCredits: "chat.turn.buyCredits"
		case .chooseAccessMethod: "chat.turn.chooseAccessMethod"
		case .signInToOpenRouter: "chat.turn.signInAgain"
		}
	}

	private func say(_ key: CatalogKey) -> String {
		model.builder.phrasebook.say(key, [:])
	}
}
