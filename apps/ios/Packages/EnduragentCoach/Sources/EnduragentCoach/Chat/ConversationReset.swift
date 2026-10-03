import Foundation

package struct ConversationReset: Sendable {
	package let chat: ChatID
	package let ledger: Ledger
	package let flushes: FlushWork
	package let clock: any Clock

	package func run(
		_ reset: ReservedReset, archiving conversation: Conversation, jobs: [FlushJob],
		access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess
	) async -> (outcome: ResetExecutionOutcome, boundary: [AthleteRecord]) {
		let stamp = OperationStamp(
			operation: .conversationReset(reset.id),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: ActionBinding(
				account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
		)
		let rows =
			conversation.outstandingRows(jobs)
			+ conversation.messagesSinceLastFlush(jobs, excluding: nil, before: reset.boundary)
		var flushed: [(job: FlushJob, outcome: FlushOutcome?, stamp: OperationStamp)] = []
		if !rows.isEmpty {
			let jobs: [FlushJob]
			do {
				jobs = try await flushes.open(covering: rows, stamp: stamp)
			} catch {
				return (.notStarted(.local(.recordStorage)), [])
			}
			for job in jobs {
				let flushStamp = await flushes.stamp(for: job)
				let messages = rows.filter { job.coverage.resolved.contains($0.ulid) }.map(
					\.message)
				let outcome = await extract(messages, access: access, stamp: flushStamp)
				flushed.append((job, outcome, flushStamp))
			}
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
		for result in flushed {
			if let outcome = result.outcome {
				await flushes.settle(result.job, outcome, stamp: result.stamp)
			}
		}
		let outcomes = flushed.map { $0.outcome ?? .failed(.local(.recordStorage)) }
		return (.started(memory: MemorySaveResult(FlushOutcome.combining(outcomes))), boundary)
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
