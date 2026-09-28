import Foundation
import Synchronization

package struct TurnAttempt: Sendable {
	package let turn: TurnID
	package let attempt: AttemptID
	package let chat: ChatID
	package let request: String
	package let slash: SlashCommand?
	package let language: LanguageResolution
	package let session: SessionSettings
	package let access: ResolvedAccess
	package let training: TrainingConnection
	package let process: ProcessID
	package let autoReset: ResetKind?

	package var models: ModelRoles {
		ModelRoles(response: access.model, session: session)
	}
}

package enum AttemptProgress: Sendable, Equatable {
	case textDelta(String)
	case attemptRestarted
	case activity(TurnActivity)
	case proposalPending(PendingProposal)
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
	let transport: any ModelTransport
	private let ledger: Ledger
	let clock: any Clock
	private let planning: Planning
	let diagnostics: DiagnosticsLog
	private let ladder: RetryLadder
	private let evidence: any TurnEvidence

	package init(
		transport: any ModelTransport,
		ledger: Ledger,
		clock: any Clock,
		planning: Planning,
		diagnostics: DiagnosticsLog,
		ladder: RetryLadder,
		evidence: any TurnEvidence
	) {
		self.transport = transport
		self.ledger = ledger
		self.clock = clock
		self.planning = planning
		self.diagnostics = diagnostics
		self.ladder = ladder
		self.evidence = evidence
	}

	package func run(
		_ attempt: TurnAttempt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws(CancellationError) -> AttemptResult {
		let prompt: TurnPrompt
		do {
			prompt = try await assemble(attempt, scope: scope, progress: progress)
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
				if let pending {
					try await prepare(
						pending, prompt: &prompt, attempt: attempt, scope: scope, progress: progress
					)
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
	) async throws {
		for preparation in retry.preparations {
			switch preparation {
			case .flushMemory(let trigger):
				try await flushOnce(
					trigger, covering: prompt.inTurnRows, attempt: attempt, scope: scope,
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
	}

	func flushOnce(
		_ trigger: FlushTrigger,
		covering rows: [(ulid: ULID, message: ChatMessage)],
		attempt: TurnAttempt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws(CancellationError) {
		guard await scope.takeFlushLatch(), !rows.isEmpty else { return }
		await progress(.activity(.savingMemory))
		let flushes = flushWork(attempt)
		let job: FlushJob
		do {
			job = try await flushes.open(trigger, covering: rows.map(\.ulid), stamp: scope.stamp)
		} catch {
			diagnostics.record(.memoryFlushFailed(attempt.chat, detail: String(describing: error)))
			return
		}
		_ = try await flushes.run(
			job, messages: rows.map(\.message),
			access: attempt.access.using(model: attempt.models.flush),
			scope: scope)
	}

	private func flushWork(_ attempt: TurnAttempt) -> FlushWork {
		FlushWork(
			chat: attempt.chat, process: attempt.process, ledger: ledger,
			memory: Memory(ledger: ledger, clock: clock),
			transport: transport, clock: clock, diagnostics: diagnostics)
	}

	private func assemble(
		_ attempt: TurnAttempt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws -> TurnPrompt {
		_ = planning
		let chatId = attempt.chat
		let stamp = scope.stamp
		let transcript = try await ledger.loadTranscript(chatId: chatId, excluding: attempt.turn)

		let memory = Memory(ledger: ledger, clock: clock)
		let context = try await memory.context()
		let view = try await memory.view()
		let schemas = tools(for: attempt).toolsForTurn(chatId: chatId, memory: view)
		let prefix = PromptAssembly.cyclingPrefix(gated: true)
		let block = try await evidence.block(
			for: attempt.training, attempt: attempt.attempt, now: clock.now)
		let replyLanguage = PromptAssembly.replyLanguageSection(resolution: attempt.language)
		let volatile = PromptAssembly.volatile(
			context: context,
			evidence: block,
			timeZoneName: clock.timeZone.identifier,
			replyLanguage: replyLanguage
		)
		let system = prefix + "\n\n" + volatile
		let history = transcript.history
		let trim = HistoryWindow.trim(
			messages: history.messages, systemTokens: estimateTokens(system),
			window: attempt.models.chatWindow, ratio: attempt.session.historyBudgetRatio.value)
		var summary = history.summary
		var kept = trim.kept
		if !trim.dropped.isEmpty {
			try await flushOnce(
				.trim, covering: transcript.window, attempt: attempt, scope: scope,
				progress: progress)
			do {
				let firstKept =
					trim.kept.isEmpty
					? transcript.current?.ulid ?? attempt.turn.ulid
					: history.ulids[trim.dropped.count]
				summary = try await summarizeDropped(
					trim.dropped, previous: summary, firstKept: firstKept, attempt: attempt,
					scope: scope, progress: progress)
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				diagnostics.record(
					.compactionFailed(chatId, detail: String(describing: error)),
					redacting: [attempt.access.credential.secret])
				kept = history.messages
			}
		} else if !transcript.flushPending,
			FlushGate.shouldQueueSoftFlush(
				estimatedHistoryTokens: history.estimatedTokens, historyBudget: trim.budget,
				messagesSinceLastFlush: transcript.unflushed.count),
			await scope.takeFlushLatch()
		{
			_ = try await flushWork(attempt).open(
				.softThreshold, covering: transcript.unflushed.map(\.ulid), stamp: stamp)
		}

		let timed = PromptAssembly.appendCurrentTime(
			athleteText: attempt.request,
			now: clock.now,
			timeZone: clock.timeZone
		)
		var wire = kept.map(wireMessage(from:))
		wire.append(WireMessage(role: .user, content: timed, toolCalls: [], toolCallId: nil))
		let archived = attempt.autoReset.map { _ in PromptAssembly.archiveMarker(at: clock.now) }
		return TurnPrompt(
			prefix: prefix, system: system, schemas: schemas, timed: timed, summary: summary,
			archiveMarker: archived, wire: wire,
			inTurnRows: transcript.window + [transcript.current].compactMap { $0 },
			window: attempt.models.chatWindow)
	}

	private func summarizeDropped(
		_ dropped: [ChatMessage], previous: String?, firstKept: ULID, attempt: TurnAttempt,
		scope: TurnScope, progress: @escaping AttemptProgressSink
	) async throws -> String {
		await progress(.activity(.compacting))
		try await scope.chargeCall()
		let summary = try await summarize(
			PromptAssembly.droppedSummaryRequest(
				previous: previous, transcript: PromptAssembly.transcript(dropped)),
			charge: .droppedSummary, attempt: attempt)
		_ = try await ledger.commit(
			synced: [
				.windowStart(
					WindowStartBody(
						chatId: attempt.chat, firstIncludedUlid: firstKept, reason: .trim)),
				.compactionSummary(CompactionSummaryBody(chatId: attempt.chat, markdown: summary)),
			],
			stamp: scope.stamp)
		return summary
	}

	func summarize(_ request: String, charge: GenerateCharge, attempt: TurnAttempt)
		async throws -> String
	{
		try await generateStep(
			request: CompletionRequest(
				access: attempt.access.using(model: attempt.models.compaction),
				attempt: attempt.attempt,
				charge: charge,
				messages: [
					WireMessage(
						role: .system, content: PromptAssembly.compactionSystem, toolCalls: [],
						toolCallId: nil),
					WireMessage(role: .user, content: request, toolCalls: [], toolCallId: nil),
				],
				tools: [],
				deadline: TurnPolicy.compactionTimeout
			),
			progress: { _ in }
		).text
	}

	func tools(for attempt: TurnAttempt) -> ToolRuntime {
		ToolRuntime(
			intervals: attempt.training.client, ledger: ledger, planning: planning, clock: clock)
	}

}

struct TurnPrompt: Sendable {
	let prefix: String
	let system: String
	let schemas: [ToolSchema]
	let timed: String
	var summary: String?
	let archiveMarker: String?
	var wire: [WireMessage]
	let inTurnRows: [(ulid: ULID, message: ChatMessage)]
	let window: Int

	var systemMessage: WireMessage {
		WireMessage(role: .system, content: system, toolCalls: [], toolCallId: nil)
	}

	var summaryMessages: [WireMessage] {
		let summaries = [summary.map(PromptAssembly.summaryMessage), archiveMarker]
		return summaries.compactMap { $0 }.map { content in
			WireMessage(role: .system, content: content, toolCalls: [], toolCallId: nil)
		}
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

private func wireMessage(from message: ChatMessage) -> WireMessage {
	WireMessage(
		role: message.role == .user ? .user : .assistant,
		content: message.text,
		toolCalls: [],
		toolCallId: nil
	)
}
