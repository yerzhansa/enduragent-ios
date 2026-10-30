import Foundation

package enum WorkoutReviewStatus: Equatable, Sendable {
	case read(PendingReview, newestEnding: ReviewOutcomeBody?)
	case unreadable
}

extension WorkoutReviewStatus {
	package var promptSection: String {
		let lines: [String]
		switch self {
		case .unreadable:
			lines = ["The review status could not be read this turn."]
		case .read(let pending, let ending):
			lines = [Self.waitingLine(pending)] + Self.endingLines(ending)
		}
		return PromptStaticBlocks.reviewStatusHeading + "\n\n" + lines.joined(separator: "\n")
	}

	private static func waitingLine(_ pending: PendingReview) -> String {
		switch pending {
		case .none:
			"No workout review waits for the athlete."
		case .waiting(let base, let remaining, let finished, let controls):
			"Review \(named(base)) waits for the athlete to \(controls.choice): \(remaining.count) "
				+ (remaining.count == 1 ? "change" : "changes")
				+ (finished > 0 ? ", \(finished) already written." : ".")
		case .running(let base):
			"Review \(named(base)) is being written to the calendar now. Nothing waits for approval."
		case .unconfirmed(let base):
			"Review \(named(base)) has an unconfirmed change: the athlete must check it again or cancel it."
		}
	}

	private static func endingLines(_ ending: ReviewOutcomeBody?) -> [String] {
		guard let ending else { return ["No workout review has ended."] }
		let opening =
			"The newest ended review, "
			+ named(ReviewBase(review: ending.review, revision: ending.revision)) + ", "
		let lines = ending.lines.sorted { $0.position < $1.position }.map { line in
			"- \(line.action.word) \(canonicalJSON(.string(sanitizeUntrustedText(line.name)))) on \(line.date.rawValue): \(line.result.words)"
		}
		switch ending.ending {
		case .completed: return [opening + "was approved and completed:"] + lines
		case .canceled: return [opening + "was canceled:"] + lines
		case .closedAtUpgrade: return [opening + "was closed by an app update."]
		}
	}

	private static func named(_ base: ReviewBase) -> String {
		"setId \(base.review.ulid.rawValue), revision \(base.revision.rawValue)"
	}
}

extension WorkoutReviewDesk {
	package func status(
		chat: ChatID, for account: TrainingAccount, using ownership: InformationOwnership
	) async -> WorkoutReviewStatus {
		do throws(LedgerFailure) {
			return .read(
				try await pending(chat: chat),
				newestEnding: try await ledger.newestReviewOutcome(
					chat: chat, visibleIn: ownership.scope(for: account, device: ledger.deviceId),
					using: ownership))
		} catch {
			diagnostics.record(.reviewUnavailable(chat, error))
			return .unreadable
		}
	}
}

extension ControlSet {
	fileprivate var choice: String {
		switch self {
		case .approveOrCancel: "approve or cancel"
		case .tryAgainOrCancel: "try again or cancel"
		case .checkAgainOrCancel: "check again or cancel"
		case .cancelOnly: "cancel, because it can no longer be approved"
		}
	}
}

extension ReviewCard.Action {
	fileprivate var word: String {
		switch self {
		case .add: "add"
		case .edit: "edit"
		case .delete: "delete"
		}
	}
}

extension OutcomeLine.Result {
	fileprivate var words: String {
		switch self {
		case .saved: "saved"
		case .seenOnCalendar: "seen on the calendar"
		case .noLongerOnCalendar: "no longer on the calendar"
		case .givenUp: "not made"
		case .mayHaveBeenSaved: "may have been saved"
		}
	}
}
