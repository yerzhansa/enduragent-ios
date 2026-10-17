import Foundation

struct LegacyProposal: Equatable, Sendable {
	let record: AthleteRecord
	let body: LegacyProposalBody

	var review: WorkoutReviewID { WorkoutReviewID(ulid: record.ulid) }

	var origin: DraftKey? {
		guard case .operation(.turn(let turn), let attempt) = record.cause else { return nil }
		return DraftKey(turn: turn, attempt: attempt)
	}
}

struct LegacyWrite: Equatable, Sendable {
	let record: AthleteRecord
	var body: ReviewWriteBody
	let proposal: LegacyProposal?
	var cancellation: ReviewCancelledUnknownBody?
}

enum LegacyReviewRecords {
	static let localScope = RecordQuery.Scope.deviceLocal(
		[], includeLegacy: [.pendingProposal, .proposalCleared])
	static let syncedScope = RecordQuery.Scope.synced(
		[], includeLegacy: [.reviewWrite, .reviewCancelledUnknown])

	static func liveProposal(in local: [AthleteRecord], chat: ChatID, now: Date)
		-> LegacyProposal?
	{
		let ordered = local.sorted { $0.hlc < $1.hlc }
		var clearedAt: [Nonce: HybridLogicalClock] = [:]
		for record in ordered {
			if case .legacy(.proposalCleared(let cleared, let nonce)) = record.body, cleared == chat {
				clearedAt[nonce] = record.hlc
			}
		}
		for record in ordered.reversed() {
			guard case .legacy(.pendingProposal(let body)) = record.body, body.chatId == chat,
				body.expiresAt > now
			else { continue }
			if let cleared = clearedAt[body.nonce], record.hlc < cleared { continue }
			return LegacyProposal(record: record, body: body)
		}
		return nil
	}

	static func writes(in chat: ChatID, synced: [AthleteRecord], local: [AthleteRecord])
		-> [LegacyWrite]
	{
		let records = synced.filter { $0.chatId == chat && syncedScope.admits($0.body) }
		var writes: [CalendarWriteKey: LegacyWrite] = [:]
		for record in records.sorted(by: { $0.hlc < $1.hlc }) {
			guard case .legacy(.reviewWrite(let body)) = record.body else { continue }
			if var known = writes[body.key] {
				guard known.record.deviceId == record.deviceId,
					known.record.account == record.account
				else { continue }
				if known.body.evidence.dispatched {
					guard known.body.review == body.review, known.body.target == body.target else {
						continue
					}
					known.body.evidence = known.body.evidence.merging(body.evidence)
					writes[body.key] = known
					continue
				}
			}
			writes[body.key] = LegacyWrite(
				record: record, body: body, proposal: proposal(body.review, in: local))
		}
		for marker in ReviewCancelledUnknownBody.validated(in: records) {
			guard case .legacy(.reviewCancelledUnknown(let body)) = marker.body,
				var write = writes[body.key], write.body.review == body.review,
				write.record.deviceId == marker.deviceId, write.record.account == marker.account
			else { continue }
			write.cancellation = body
			writes[body.key] = write
		}
		return writes.values.sorted { $0.record.hlc < $1.record.hlc }
	}

	private static func proposal(_ review: WorkoutReviewID, in local: [AthleteRecord])
		-> LegacyProposal?
	{
		for record in local where record.ulid == review.ulid {
			if case .legacy(.pendingProposal(let body)) = record.body {
				return LegacyProposal(record: record, body: body)
			}
		}
		return nil
	}
}
