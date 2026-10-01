import Foundation

public enum ResetOutcome: Sendable, Equatable {
	case started(memory: MemorySaveResult)
	case notStarted(CoachFailure)
}

public enum MemorySaveResult: Sendable, Equatable {
	case providerConsentRequired
	case saved
	case partiallySaved
	case notSaved

	init(_ outcome: FlushOutcome?) {
		switch outcome {
		case .saved, .nothingToSave: self = .saved
		case .partial: self = .partiallySaved
		case .failed(.model(.accessUnavailable(.providerConsentRequired))):
			self = .providerConsentRequired
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
		_ reset: ReservedReset, archiving conversation: Conversation, jobs: [FlushJob],
		access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess
	) async -> (outcome: ResetOutcome, boundary: [AthleteRecord]) {
		let stamp = OperationStamp(
			operation: .conversationReset(reset.id),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: ActionBinding(
				account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
		)
		let rows =
			conversation.outstandingRows(jobs)
			+ conversation.messagesSinceLastFlush(jobs, excluding: nil, before: reset.boundary)
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
							chatId: chat, firstIncludedUlid: reset.id.ulid,
							reason: .reset(reset.id), boundaryClock: reset.boundary))
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
		} catch .providerConsentRequired {
			return .failed(.model(.accessUnavailable(.providerConsentRequired)))
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
		_ reset: ReservedReset, on records: ChatRecords,
		access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess,
		isolation: isolated (any Actor)? = #isolation, then publish: () -> Void
	) async {
		_ = await records.refreshJobs(from: work.flushes)
		let result = await work.run(
			reset, archiving: records.conversation, jobs: records.jobs, access: access)
		records.apply(result.boundary)
		_ = await records.refreshJobs(from: work.flushes)
		publish()
		finish(reset.id, result.outcome)
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
	package mutating func openSegment(
		at ulid: ULID, boundary: SegmentBoundary, openedBy opening: SegmentOpening
	) {
		guard !segments.contains(where: { $0.id.boundary == ulid }) else { return }
		var opened = Segment(id: SegmentID(boundary: ulid), openedBy: opening, boundary: boundary)
		let last = segments.lastIndex { $0.boundary.map { $0.precedes(boundary) } ?? true } ?? 0
		if !segments.isEmpty {
			opened.notes = segments[last].notes.filter { boundary.includes($0.ulid, at: $0.hlc) }
			segments[last].notes.removeAll { boundary.includes($0.ulid, at: $0.hlc) }
		}
		segments.insert(opened, at: last + 1)
	}
}

extension Segment {
	package func closing(at boundary: HybridLogicalClock) -> Segment {
		var closing = self
		closing.turns.removeAll { $0.opens(atOrAfter: boundary) }
		closing.notes.removeAll { $0.hlc >= boundary }
		return closing
	}
}

extension TurnFacts {
	fileprivate func opens(atOrAfter boundary: HybridLogicalClock) -> Bool {
		fragments.min(by: { $0.index < $1.index }).map { $0.hlc >= boundary } ?? false
	}
}
