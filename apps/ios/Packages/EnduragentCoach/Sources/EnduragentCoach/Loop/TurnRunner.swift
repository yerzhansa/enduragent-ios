import Foundation
import Synchronization

package enum AttemptOrigin: Sendable, Equatable {
	case send
	case retry
}

package struct TurnAttempt: Sendable {
	package let turn: TurnID
	package let attempt: AttemptID
	package let origin: AttemptOrigin
	package let chat: ChatID
	package let request: String
	package let slash: SlashCommand?
	package let displayLocale: DisplayLocale
	package let session: SessionSettings
	package let access: ResolvedAccess
	package let training: TrainingConnection
	package let process: ProcessID
}

package enum AttemptProgress: Sendable, Equatable {
	case textDelta(String)
	case attemptRestarted
	case activity(TurnActivity)
}

package enum AttemptResult: Sendable, Equatable {
	case replied(ReplyText, lineage: ReplyLineage)
	case savedWork(SavedWorkOutcome, saved: WriteSummary)
	case failed(CoachFailure, saved: WriteSummary)
}

extension Settlement {
	package init(_ result: AttemptResult) {
		switch result {
		case .replied(let text, let lineage):
			self = .replied(text, lineage: lineage)
		case .savedWork(let outcome, let saved):
			self = .savedWork(outcome, saved: saved)
		case .failed(let failure, let saved):
			self = .failed(failure, saved: saved)
		}
	}
}

package typealias AttemptProgressSink = @Sendable (AttemptProgress) async -> Void

package struct TurnRunner: Sendable {
	private static let droppedMessageLimit = 1_024

	let transport: any ModelTransport
	let authorizeInvocation: @Sendable (ModelInvocation) async throws -> Void
	private let ledger: Ledger
	let clock: any Clock
	let watchdogSleep: @Sendable (Duration) async throws(CancellationError) -> Void
	let diagnostics: DiagnosticsLog
	let ladder: RetryLadder
	let desk: WorkoutReviewDesk
	let plans: Plans
	private let snapshots: TrainingSnapshotReader

	package init(
		transport: any ModelTransport,
		ledger: Ledger,
		clock: any Clock,
		diagnostics: DiagnosticsLog,
		ladder: RetryLadder,
		desk: WorkoutReviewDesk,
		plans: Plans,
		watchdogSleep: @escaping @Sendable (Duration) async throws(CancellationError) -> Void =
			SystemClock().sleep,
		authorizeInvocation: @escaping @Sendable (ModelInvocation) async throws -> Void
	) {
		self.authorizeInvocation = authorizeInvocation
		self.transport = transport
		self.ledger = ledger
		self.clock = clock
		self.watchdogSleep = watchdogSleep
		self.diagnostics = diagnostics
		self.ladder = ladder
		self.snapshots = TrainingSnapshotReader(
			clock: clock, deadlineSleep: watchdogSleep, diagnostics: diagnostics)
		self.desk = desk
		self.plans = plans
	}

	package func run(
		_ attempt: TurnAttempt,
		conversation: Conversation, jobs: [FlushJob],
		scope: TurnScope,
		committed: @escaping @Sendable ([AthleteRecord]) async -> Void,
		progress: @escaping AttemptProgressSink
	) async throws(CancellationError) -> AttemptResult {
		let prompt: TurnPrompt
		do {
			prompt = try await assemble(
				attempt,
				transcript: Transcript(
					conversation: conversation, jobs: jobs, excluding: attempt.turn,
					for: attempt.training.account, device: ledger.deviceId,
					using: try await ledger.informationOwnership()),
				scope: scope, committed: committed, progress: progress)
		} catch {
			let failure = try AttemptFailure(caught: error)
			return .failed(
				failure.coachFailure(for: attempt.access.method), saved: await scope.summary)
		}
		return try await attempts(attempt, prompt: prompt, scope: scope, progress: progress)
	}

	private func attempts(
		_ attempt: TurnAttempt,
		prompt initial: TurnPrompt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws(CancellationError) -> AttemptResult {
		var prompt = initial
		var counters = RetryCounters.zero
		var pending: RetryPlan?
		while true {
			let observed = TextObservation()
			do {
				if let pending,
					let outcome = try await prepare(
						pending, prompt: &prompt, attempt: attempt, scope: scope, progress: progress
					)
				{
					return .savedWork(outcome, saved: await scope.summary)
				}
				pending = nil
				return try await generate(
					attempt, prompt: &prompt, scope: scope, progress: observed.watching(progress))
			} catch {
				let failure = try AttemptFailure(caught: error)
				let situation = AttemptSituation(
					committed: await scope.written,
					observedText: observed.seen,
					promptTokens: prompt.estimatedTokens,
					effectiveWindow: prompt.window,
					flushLatchFree: await scope.flushLatchFree,
					accessMethod: attempt.access.method,
					jitter: Double.random(in: 0..<1)
				)
				let saved = await scope.summary
				switch ladder.decide(failure, situation: situation, counters: counters) {
				case .terminal(let coachFailure):
					return .failed(coachFailure, saved: saved)
				case .settleSavedWork(let outcome):
					return .savedWork(outcome, saved: saved)
				case .retry(let next, let preparations):
					counters = next
					pending = RetryPlan(failure: failure, preparations: preparations)
					let key = DraftKey(turn: attempt.turn, attempt: attempt.attempt)
					await desk.abandonDraft(key)
					_ = await plans.settle(key, in: attempt.chat, ending: .abandoned)
					await progress(.attemptRestarted)
				}
			}
		}
	}

	private func prepare(
		_ retry: RetryPlan,
		prompt: inout TurnPrompt,
		attempt: TurnAttempt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws -> SavedWorkOutcome? {
		for preparation in retry.preparations {
			switch preparation {
			case .flushMemory:
				try await flushOnce(
					covering: prompt.inTurnRows, attempt: attempt, scope: scope,
					progress: progress)
			case .compactInTurn:
				do {
					try await compact(&prompt, attempt: attempt, scope: scope, progress: progress)
				} catch is CancellationError {
					throw CancellationError()
				} catch {
					throw AttemptFailure.rescueFailed(retry.failure)
				}
			case .wait(let duration, let reason):
				let until = clock.now.addingTimeInterval(duration.timeInterval)
				await progress(.activity(.waiting(RetryWait(until: until, reason: reason))))
				try await clock.sleep(for: duration)
				try await scope.checkDeadline(uptime: clock.uptime)
			}
		}
		return await scope.savedWork()
	}

	func flushOnce(
		covering rows: [ConversationRow],
		attempt: TurnAttempt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws(CancellationError) {
		guard await scope.takeFlushLatch(), !rows.isEmpty else { return }
		await progress(.activity(.savingMemory))
		let flushes = flushWork(attempt)
		let jobs: [FlushJob]
		do {
			jobs = try await flushes.open(covering: rows, stamp: scope.stamp)
		} catch {
			diagnostics.record(.memoryFlushFailed(attempt.chat, FailureCode(error)))
			return
		}
		for job in jobs {
			_ = try await flushes.run(job, rows: rows, access: attempt.access, scope: scope)
		}
	}

	private func flushWork(_ attempt: TurnAttempt) -> FlushWork {
		FlushWork(
			chat: attempt.chat, process: attempt.process, ledger: ledger,
			memory: Memory(
				ledger: ledger, clock: clock, watchdogSleep: watchdogSleep,
				authorizeInvocation: authorizeInvocation),
			transport: transport, clock: clock, diagnostics: diagnostics, ladder: ladder)
	}

	private func assemble(
		_ attempt: TurnAttempt, transcript: Transcript,
		scope: TurnScope,
		committed: @escaping @Sendable ([AthleteRecord]) async -> Void,
		progress: @escaping AttemptProgressSink
	) async throws -> TurnPrompt {
		let chatId = attempt.chat
		let stamp = scope.stamp

		let memory = Memory(ledger: ledger, clock: clock)
		let (context, view) = try await memory.prompt(for: attempt.training.account)
		let offer = ToolOffer(
			for: TurnReach(
				training: attempt.training, memory: view, chat: attempt.chat, ledger: ledger,
				clock: clock, desk: desk, plans: plans,
				attempt: DraftKey(turn: attempt.turn, attempt: attempt.attempt)))
		let prefix = PromptAssembly.cyclingPrefix()
		let snapshot = try await snapshots.snapshot(
			for: attempt.training, attempt: attempt.attempt)
		let zone = clock.timeZone
		let volatile = PromptAssembly.volatile(
			context: context,
			snapshot: snapshot,
			timeZoneName: zone.identifier,
			displayLocale: attempt.displayLocale
		)
		let system = prefix + "\n\n" + volatile
		let history = transcript.history
		let past = history.rows.map(\.message).map { PromptAssembly.wireMessage(from: $0) }
		let trim = HistoryWindow.trim(
			messages: past, systemTokens: estimateTokens(system),
			window: attempt.session.effectiveContextWindow,
			ratio: attempt.session.historyBudgetRatio.value)
		var summary = history.summary
		var kept = trim.kept
		if !trim.dropped.isEmpty {
			try await flushOnce(
				covering: transcript.window, attempt: attempt, scope: scope,
				progress: progress)
			do {
				let firstKept =
					trim.kept.isEmpty
					? transcript.current?.ulid ?? attempt.turn.ulid
					: history.rows.map(\.ulid)[trim.dropped.count]
				let dropped = try await summarizeDropped(
					trim.dropped, previous: summary, firstKept: firstKept, attempt: attempt,
					droppedUlids: Array(history.rows.map(\.ulid).prefix(trim.dropped.count)),
					scope: scope, progress: progress)
				await committed(dropped.records)
				summary = dropped.summary
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				diagnostics.record(.compactionFailed(chatId, FailureCode(error)))
				kept = past
			}
		} else if !transcript.flushPending,
			FlushGate.shouldQueueSoftFlush(
				estimatedHistoryTokens: HistoryWindow.estimatedTokens(
					summary: history.summary, messages: past),
				historyBudget: trim.budget,
				messagesSinceLastFlush: transcript.unflushed.count),
			await scope.takeFlushLatch()
		{
			_ = try await flushWork(attempt).open(
				covering: transcript.unflushed, stamp: stamp)
		}

		let timed = PromptAssembly.appendCurrentTime(
			athleteText: attempt.request,
			now: clock.now,
			timeZone: zone
		)
		var wire = kept
		wire.append(WireMessage(role: .user, content: timed, toolCalls: [], toolCallId: nil))
		return TurnPrompt(
			prefix: prefix, system: system, offer: offer, timed: timed, summary: summary,
			wire: wire,
			inTurnRows: transcript.window + [transcript.current].compactMap { $0 },
			window: attempt.session.effectiveContextWindow)
	}

	private func summarizeDropped(
		_ dropped: [WireMessage], previous: String?, firstKept: ULID, attempt: TurnAttempt,
		droppedUlids: [ULID], scope: TurnScope, progress: @escaping AttemptProgressSink
	) async throws -> (summary: String, records: [AthleteRecord]) {
		await progress(.activity(.compacting))
		try await scope.chargeCall()
		let summary = try await Compactor(modelCall: modelCall).summarize(
			dropped, previous: previous, purpose: .droppedHistory, attempt: attempt)
		let windows = stride(from: 0, to: droppedUlids.count, by: Self.droppedMessageLimit).map {
			start in
			SyncedRecordBody.windowStart(
				WindowStartBody(
					chatId: attempt.chat, firstIncludedUlid: firstKept, reason: .trim,
					droppedMessageUlids: Array(
						droppedUlids[
							start..<min(start + Self.droppedMessageLimit, droppedUlids.count)])))
		}
		let records = try await ledger.commit(
			synced: windows + [
				.compactionSummary(
					CompactionSummaryBody(chatId: attempt.chat, markdown: summary.markdown))
			],
			stamp: scope.stamp)
		return (summary.markdown, records)
	}

}

struct TurnPrompt: Sendable {
	let prefix: String
	let system: String
	let offer: ToolOffer
	let timed: String
	var summary: String?
	var wire: [WireMessage]
	let inTurnRows: [ConversationRow]
	let window: Int

	var systemMessage: WireMessage {
		WireMessage(role: .system, content: system, toolCalls: [], toolCallId: nil)
	}

	var summaryMessages: [WireMessage] {
		summary.map {
			[
				WireMessage(
					role: .system, content: PromptAssembly.summaryMessage($0), toolCalls: [],
					toolCallId: nil)
			]
		} ?? []
	}

	var estimatedTokens: Int {
		(summaryMessages + wire).reduce(0) { $0 + estimateTokens($1.content) }
			+ estimateTokens(system)
	}

	var overBudget: Bool {
		estimatedTokens > window - TurnPolicy.reserveTokens
	}
}

private struct RetryPlan: Sendable {
	let failure: AttemptFailure
	let preparations: [RetryPreparation]
}

private final class TextObservation: Sendable {
	private let state = Mutex(false)

	var seen: Bool {
		state.withLock { $0 }
	}

	func watching(_ progress: @escaping AttemptProgressSink) -> AttemptProgressSink {
		{ event in
			if case .textDelta(let delta) = event, !delta.isEmpty {
				self.state.withLock { $0 = true }
			}
			await progress(event)
		}
	}
}
