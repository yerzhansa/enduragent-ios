import EnduragentCoach
import SwiftUI

struct TurnRowView: View {
	var model: ShellModel
	var turn: TurnView

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if let athleteText = turn.athleteText {
				Text(athleteText)
			}
			switch turn.state {
			case .accepted(.awaitingRestart):
				Text(say(Catalog.chatTurnReceivedBeforeClose))
					.accessibilityIdentifier("chat.turn.receivedBeforeClose")
				actionButton(.tryAgain(turn.id))
			case .accepted(.onOtherDevice), .accepted(.beforeUpgrade):
				EmptyView()
			case .accepted(.collecting), .accepted(.queued):
				working
			case .processing:
				if let reply = model.chat?.liveReply, reply.turn == turn.id, !reply.text.isEmpty {
					ReplyView(source: reply.text, parser: model.services.replyParser)
				}
				working
			case .completed(let completed):
				ReplyView(
					source: completed.reply.sentence(in: model.phrasebook),
					parser: model.services.replyParser)
				if turn.completedInBackground {
					Text(say(Catalog.chatTurnFinishedWhileLocked))
						.font(.footnote)
						.foregroundStyle(.secondary)
						.accessibilityIdentifier("chat.turn.finishedWhileLocked")
				}
			case .savedWork(let savedWork):
				notice(savedWork.notice)
			case .failed(let failed):
				notice(failed.notice)
			case .interrupted(let interrupted):
				if !interrupted.partial.isEmpty {
					ReplyView(source: interrupted.partial, parser: model.services.replyParser)
						.foregroundStyle(.secondary)
						.opacity(0.6)
				}
				notice(interrupted.notice)
			case .unrecovered(let unrecovered):
				notice(unrecovered.notice)
			}
			if let failure = turn.saveFailure {
				Text(say(failure))
					.foregroundStyle(.secondary)
					.accessibilityIdentifier("chat.turn.saveFailure")
			}
		}
		.fixedSize(horizontal: false, vertical: true)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var working: some View {
		Text(say(Catalog.chatNoticeWorking))
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("chat.working")
	}

	private func notice(_ notice: AthleteNotice) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(notice.sentence(in: model.phrasebook))
				.accessibilityIdentifier("chat.turn.notice")
			if let action = notice.action {
				actionButton(action)
			}
		}
	}

	private func actionButton(_ action: RecoveryAction) -> some View {
		Button(say(action.title)) {
			Task { await model.perform(action) }
		}
		.disabled(isWaiting(action))
		.accessibilityIdentifier(identifier(for: action))
	}

	private func isWaiting(_ action: RecoveryAction) -> Bool {
		guard case .wait = action else { return false }
		return true
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
		model.phrasebook.say(key, [:])
	}
}
