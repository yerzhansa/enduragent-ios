import Foundation

package struct RecoveryPlan: Sendable, Equatable {
	package var interrupt: [DeadClaim]
	package var drain: [FlushJobID] = []

	package var isEmpty: Bool {
		interrupt.isEmpty && drain.isEmpty
	}
}

package struct DeadClaim: Sendable, Equatable {
	package let turn: TurnID
	package let attempt: AttemptID
	package let saved: WriteSummary
}

package enum TurnRecovery {
	package static let localScope: RecordQuery.Scope = .deviceLocal([
		.turnClaim, .replyObserved, .flushPending, .flushSettled,
	])
	package static let stampedWrites: RecordQuery.Scope = .synced([
		.memorySection, .dailyNote, .ledgerEvent,
	])

	package static func plan(
		turns: [TurnFacts], drain: [FlushJobID] = [], writes: [AttemptID: WriteSummary],
		device: DeviceID, process: ProcessID
	) -> RecoveryPlan {
		RecoveryPlan(
			interrupt: turns.filter { $0.origin == device }.compactMap { facts in
				guard let open = facts.openClaim, open.process != process else { return nil }
				return DeadClaim(
					turn: facts.turn, attempt: open.attempt,
					saved: writes[open.attempt, default: .none])
			},
			drain: drain)
	}

	static func plans(
		in conversations: [ChatID: Conversation], jobs: [ChatID: [FlushJob]],
		writes: [AttemptID: WriteSummary], device: DeviceID, process: ProcessID
	) -> [ChatID: RecoveryPlan] {
		conversations.compactMapValues { conversation in
			let drain = FlushJob.outstanding(jobs[conversation.chat] ?? [], in: conversation)
			let plan = plan(
				turns: conversation.segments.flatMap(\.turns), drain: drain.map(\.id),
				writes: writes, device: device, process: process)
			return plan.isEmpty ? nil : plan
		}
	}

	package static func writes(of attempts: Set<AttemptID>, in records: [AthleteRecord])
		-> [AttemptID: WriteSummary]
	{
		var commits: [AttemptID: [CommittedWrite]] = [:]
		for record in records {
			guard case .operation(_, let attempt) = record.cause, attempts.contains(attempt),
				let commit = CommittedWrite(stamped: record.body)
			else {
				continue
			}
			commits[attempt, default: []].append(commit)
		}
		return commits.mapValues(WriteSummary.init)
	}
}

extension CommittedWrite {
	fileprivate init?(stamped body: RecordBody) {
		switch body {
		case .synced(.memorySection), .synced(.dailyNote):
			self.init(tool: .memoryWrite)
		case .synced(.ledgerEvent):
			self.init(tool: .ledgerAppend)
		default:
			return nil
		}
	}
}
