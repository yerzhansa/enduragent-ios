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
				tryAgain
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

	private var tryAgain: some View {
		Button(say(Catalog.chatTranscriptRetry)) {
			Task { await model.perform(.tryAgain(turn.id)) }
		}
		.accessibilityIdentifier("chat.turn.tryAgain")
	}

	private func notice(_ notice: AthleteNotice) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(
				model.builder.phrasebook.say(notice.key, notice.vars)
					.trimmingCharacters(in: .whitespacesAndNewlines)
			)
			.accessibilityIdentifier("chat.turn.notice")
			if let action = notice.action {
				switch action {
				case .tryAgain:
					tryAgain
				}
			}
		}
	}

	private func say(_ key: CatalogKey) -> String {
		model.builder.phrasebook.say(key, [:])
	}
}
