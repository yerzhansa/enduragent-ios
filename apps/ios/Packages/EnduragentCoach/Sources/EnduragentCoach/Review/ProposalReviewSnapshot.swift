import Foundation

extension SingleProposalReviews {
	package func snapshot(chat: ChatID, records: [AthleteRecord]? = nil) async throws(LedgerFailure)
		-> ReviewSnapshot?
	{
		let previous = deliveries[chat]?.ref
		let intents = try await ledger.calendarWrites(chat, synced: records)
		guard deliveries[chat]?.ref == previous else { return try await snapshot(chat: chat) }
		if let intent = intents.first(where: {
			$0.blocksNewWork && !closed.contains($0.body.review)
		}) {
			return try await recoverySnapshot(intent, chat: chat)
		}
		guard
			let live = try await ProposalPolicy.live(chatId: chat, ledger: ledger, now: clock.now),
			!closed.contains(ChangeSetID(ulid: live.ulid)),
			!intents.contains(where: {
				$0.body.review.ulid == live.ulid
					&& ($0.body.evidence.applied || $0.cancellation != nil)
			})
		else {
			deliveries[chat] = nil
			guard let intent = intents.last(where: { $0.cancellation != nil }),
				let body = intent.cancellation
			else {
				return nil
			}
			return ReviewSnapshot(
				ref: ReviewRef(
					chat: chat, set: body.review, revision: ChangeSetRevision(rawValue: 1),
					delivery: UUID()),
				state: .cancelledUnknown(CancelledUnknownReview(body)),
				attribution: try await attribution(for: intent.record.account))
		}
		let attribution = try await attribution(for: live.account)
		let block = await accountBlock(live.account)
		guard deliveries[chat]?.ref == previous else { return try await snapshot(chat: chat) }
		let delivery = delivery(
			set: ChangeSetID(ulid: live.ulid), chat: chat,
			authority: live.cause == .legacy ? .readOnly : .thisDevice)
		let card = ReviewCard(live.body)
		let notice: ReviewNotice? =
			block == .cannotVerify
			? ReviewNotice(
				kind: .partialFailure, key: Catalog.reviewCannotVerify,
				vars: ["service": "intervals.icu"])
			: block.map(accountNotice)
		return ReviewSnapshot(
			ref: delivery.ref,
			state: .available(
				ReviewContent(
					cards: [card], kept: [], totals: ReviewTotals([card]), receipts: [],
					notice: delivery.authority == .readOnly
						? AthleteNotices.earlierVersion
						: notice,
					authority: delivery.authority),
				block == nil ? delivery.controls : .none), attribution: attribution)
	}

	func attribution(for account: TrainingAccount) async throws(LedgerFailure) -> AthleteAttribution
	{
		AthleteAttribution(
			accounts: [account], using: try await ledger.informationOwnership(),
			device: ledger.deviceId)
	}

}

struct ReviewDelivery {
	let authority: ReviewAuthority
	var ref: ReviewRef
	var secret: UUID?
	var busy = false

	var controls: ReviewControls {
		guard authority == .thisDevice, !busy, let secret else { return .none }
		return .approveOrCancel(ReviewControlToken(ref: ref, secret: secret))
	}
}
