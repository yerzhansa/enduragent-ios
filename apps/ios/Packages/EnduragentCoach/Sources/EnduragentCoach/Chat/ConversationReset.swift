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
		access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess
	) async -> (outcome: ResetOutcome, boundary: [AthleteRecord]) {
		let stamp = OperationStamp(
			operation: .conversationReset(reset),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: ActionBinding(
				account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
		)
		let jobs = await flushes.jobs(in: conversation)
		let rows =
			conversation.outstandingRows(jobs)
			+ conversation.messagesSinceLastFlush(jobs, excluding: nil, before: reset.ulid)
		var flushed: (job: FlushJob, outcome: FlushOutcome?, stamp: OperationStamp)?
		if !rows.isEmpty {
			let job: FlushJob
			do {
				job = try await flushes.open(covering: rows.map(\.ulid), stamp: stamp)
			} catch {
				return (.notStarted(.local(.recordStorage)), [])
			}
			let flushStamp = await flushes.stamp(for: job)
			let outcome = await extract(rows.map(\.message), access: access, stamp: flushStamp)
			flushed = (job, outcome, flushStamp)
		}
		let boundary: [AthleteRecord]
		do {
			boundary = try await ledger.commit(
				synced: [
					.windowStart(
						WindowStartBody(
							chatId: chat, firstIncludedUlid: reset.ulid,
							reason: .reset(reset)))
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
		_ messages: [ChatMessage],
		access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess,
		stamp: OperationStamp
	) async -> FlushOutcome? {
		let resolved: ResolvedAccess
		do {
			resolved = try await access()
		} catch {
			flushes.diagnostics.record(.memoryFlushFailed(chat, detail: "\(error)"))
			return nil
		}
		do {
			return try await flushes.extract(
				messages: messages, access: resolved, scope: nil, stamp: stamp)
		} catch {
			flushes.diagnostics.record(.memoryFlushFailed(chat, detail: "\(error)"))
			return nil
		}
	}
}

final class PendingResets {
	private let work: ConversationReset
	private var waiting: [ResetID: CheckedContinuation<ResetOutcome, Never>] = [:]
	private var finished: [ResetID: ResetOutcome] = [:]

	init(_ work: ConversationReset) {
		self.work = work
	}

	func outcome(of reset: ResetID, isolation: isolated (any Actor)? = #isolation) async
		-> ResetOutcome
	{
		if let done = finished.removeValue(forKey: reset) {
			return done
		}
		return await withCheckedContinuation { waiting[reset] = $0 }
	}

	func run(
		_ reset: ResetID, on records: ChatRecords,
		access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess,
		isolation: isolated (any Actor)? = #isolation, then publish: () -> Void
	) async {
		let result = await work.run(reset, archiving: records.conversation, access: access)
		records.apply(result.boundary)
		_ = await records.refreshJobs(from: work.flushes)
		publish()
		finish(reset, result.outcome)
	}

	private func finish(_ reset: ResetID, _ outcome: ResetOutcome) {
		guard let waiter = waiting.removeValue(forKey: reset) else {
			finished[reset] = outcome
			return
		}
		waiter.resume(returning: outcome)
	}
}

extension Conversation {
	package mutating func openSegment(at boundary: ULID, openedBy opening: SegmentOpening) {
		guard !segments.contains(where: { $0.id.boundary == boundary }) else { return }
		var opened = Segment(id: SegmentID(boundary: boundary), openedBy: opening)
		let last = segmentIndex(for: boundary)
		if !segments.isEmpty {
			opened.turns = segments[last].turns.filter { $0.opens(atOrAfter: boundary) }
			opened.notes = segments[last].notes.filter { $0.ulid >= boundary }
			segments[last] = segments[last].closing(at: boundary)
		}
		segments.insert(opened, at: last + 1)
	}
}

extension Segment {
	package func closing(at boundary: ULID) -> Segment {
		var closing = self
		closing.turns.removeAll { $0.opens(atOrAfter: boundary) }
		closing.notes.removeAll { $0.ulid >= boundary }
		return closing
	}
}

extension TurnFacts {
	fileprivate func opens(atOrAfter boundary: ULID) -> Bool {
		fragments.first.map { $0.ulid >= boundary } ?? false
	}
}
