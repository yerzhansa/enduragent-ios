import Foundation

public enum ResetOutcome: Sendable, Equatable {
	case started(memory: MemorySaveResult)
	case notStarted(CoachFailure)
}

public enum MemorySaveResult: Sendable, Equatable {
	case saved
	case partiallySaved
	case notSaved

	init(_ outcome: FlushOutcome?) {
		switch outcome {
		case .saved, .nothingToSave: self = .saved
		case .partial: self = .partiallySaved
		case .failed, nil: self = .notSaved
		}
	}
}

package struct ConversationReset: Sendable {
	package let chat: ChatID
	package let ledger: Ledger
	package let flushes: FlushWork
	package let clock: any Clock

	package func run(
		_ reset: ResetID, archiving conversation: Conversation,
		access: @Sendable () throws(AccessUnavailable) -> ResolvedAccess
	) async -> (outcome: ResetOutcome, boundary: [AthleteRecord]) {
		let stamp = OperationStamp(
			operation: .conversationReset(reset),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: ActionBinding(
				account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
		)
		let rows = conversation.current
			.messagesSinceLastFlush(await flushes.jobs(), excluding: nil)
			.filter { $0.ulid < reset.ulid }
		var flushed: (job: FlushJob, outcome: FlushOutcome?, stamp: OperationStamp)?
		if !rows.isEmpty {
			let job: FlushJob
			do {
				job = try await flushes.open(
					.explicitReset, covering: rows.map(\.ulid), stamp: stamp)
			} catch {
				return (.notStarted(.local(.recordStorage)), [])
			}
			let flushStamp = await flushes.stamp(for: job)
			let outcome = await extract(
				job, rows.map(\.message), access: access, stamp: flushStamp)
			flushed = (job, outcome, flushStamp)
		}
		let boundary: [AthleteRecord]
		do {
			boundary = try await ledger.commit(
				synced: [
					.windowStart(
						WindowStartBody(
							chatId: chat, firstIncludedUlid: reset.ulid,
							reason: .reset(.explicit(reset))))
				],
				stamp: stamp)
		} catch {
			return (.notStarted(.local(.recordStorage)), [])
		}
		if let flushed, let outcome = flushed.outcome {
			await flushes.settle(flushed.job, outcome, stamp: flushed.stamp)
		}
		return (.started(memory: flushed.map { MemorySaveResult($0.outcome) } ?? .saved), boundary)
	}

	private func extract(
		_ job: FlushJob, _ messages: [ChatMessage],
		access: @Sendable () throws(AccessUnavailable) -> ResolvedAccess, stamp: OperationStamp
	) async -> FlushOutcome? {
		let resolved: ResolvedAccess
		do {
			resolved = try access()
		} catch {
			flushes.diagnostics.record(.memoryFlushFailed(chat, detail: "\(error)"))
			return nil
		}
		do {
			return try await flushes.extract(
				job, messages: messages, access: resolved, scope: nil, stamp: stamp)
		} catch {
			flushes.diagnostics.record(.memoryFlushFailed(chat, detail: "\(error)"))
			return nil
		}
	}
}

final class PendingResets {
	private let work: ConversationReset
	private var waiting: [ResetID: CheckedContinuation<ResetOutcome, Never>] = [:]

	init(_ work: ConversationReset) {
		self.work = work
	}

	func outcome(
		of reset: ResetID, isolation: isolated (any Actor)? = #isolation, queue: () -> Void
	) async -> ResetOutcome {
		await withCheckedContinuation { continuation in
			waiting[reset] = continuation
			queue()
		}
	}

	func run(
		_ reset: ResetID, on records: ChatRecords,
		access: @Sendable () throws(AccessUnavailable) -> ResolvedAccess,
		isolation: isolated (any Actor)? = #isolation
	) async {
		let result = await work.run(reset, archiving: records.conversation, access: access)
		records.apply(result.boundary)
		waiting.removeValue(forKey: reset)?.resume(returning: result.outcome)
	}
}

extension Conversation {
	package mutating func openSegment(at boundary: ULID, openedBy opening: SegmentOpening) {
		var opened = Segment(id: SegmentID(boundary: boundary), openedBy: opening)
		if let last = segments.indices.last {
			let moved = segments[last].turns.filter { facts in
				facts.fragments.first.map { $0.ulid >= boundary } ?? false
			}
			segments[last].turns.removeAll { facts in moved.contains { $0.turn == facts.turn } }
			opened.turns = moved
		}
		segments.append(opened)
	}
}
