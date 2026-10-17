import Foundation

package actor WorkoutReviewDesk {
	private let ledger: Ledger
	private let clock: any Clock
	private var preparations: [DraftKey: Preparing] = [:]

	package init(ledger: Ledger, clock: any Clock) {
		self.ledger = ledger
		self.clock = clock
	}

	package func prepare(
		_ request: PreparationRequest, for key: DraftKey, chat: ChatID, binding: ActionBinding,
		reads: any CalendarReads
	) async -> PreparationReply {
		preparations[key] = .reading
		do throws(PreparationRefusal) {
			let draft = try await Preparation.draft(
				request, key: key, chat: chat, binding: binding, head: try await head(of: chat),
				reads: reads, today: IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
			)
			preparations[key] = .drafted(draft)
			return switch draft.content {
			case .incomplete: .incomplete
			case .changes(let remaining, _): .drafted(changes: remaining.count, base: draft.base)
			}
		} catch {
			preparations[key] = .refused(error)
			return .refused(error)
		}
	}

	package func pending(chat: ChatID) async throws(LedgerFailure) -> PendingReview {
		PendingReview(try await ledger.reviewHead(chat: chat).1)
	}

	private func head(of chat: ChatID) async throws(PreparationRefusal) -> WorkoutReview? {
		do {
			return try await ledger.reviewHead(chat: chat).1
		} catch {
			throw .storageUnavailable
		}
	}
}
