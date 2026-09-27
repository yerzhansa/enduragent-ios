import Foundation
import Synchronization

public enum TurnPolicy {
	public static let compactionTimeout: Duration = .seconds(120)
	public static let toolResultTokenCap = 24_000
	public static let athleteContextChars = 20_000
	public static let historyBudgetFloor = 8_000
	public static let historyTokenBudgetRatio = 0.3
	public static let contextWindowCap = 200_000
	public static let reserveTokens = 20_000
	public static let dailyResetHour = 4
	public static let dailyResetGrace: Duration = .seconds(30 * 60)
	public static let proposalTTL: Duration = .seconds(10 * 60)
	public static let ungatedPrefixTokenCeiling = 13_200
	public static let gatedPrefixTokenCeiling = 13_600
}

package struct TurnAttempt: Sendable {
	package let turn: TurnID
	package let attempt: AttemptID
	package let chat: ChatID
	package let request: String
	package let slash: SlashCommand?
	package let language: LanguagePreference
	package let access: ResolvedAccess
	package let training: TrainingConnection
	package let process: ProcessID
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
	private let transport: any ModelTransport
	private let ledger: Ledger
	private let clock: any Clock
	private let planning: Planning
	private let diagnostics: DiagnosticsLog
	private let ladder: RetryLadder

	package init(
		transport: any ModelTransport,
		ledger: Ledger,
		clock: any Clock,
		planning: Planning,
		diagnostics: DiagnosticsLog,
		ladder: RetryLadder
	) {
		self.transport = transport
		self.ledger = ledger
		self.clock = clock
		self.planning = planning
		self.diagnostics = diagnostics
		self.ladder = ladder
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
					effectiveWindow: TurnPolicy.contextWindowCap,
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

	private func flushOnce(
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
			job, messages: rows.map(\.message), access: attempt.access, scope: scope)
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
		var transcript = try await loadTranscript(chatId: chatId, excluding: attempt.turn)
		if shouldDailyReset(last: transcript.lastDate) {
			if !transcript.window.isEmpty {
				_ = try await flushWork(attempt).open(
					.staleReset, covering: transcript.window.map(\.ulid), stamp: stamp)
			}
			let marker = await ledger.nextULID()
			_ = try await ledger.commit(
				synced: [
					.windowStart(
						WindowStartBody(
							chatId: chatId, firstIncludedUlid: marker, reason: .reset(.daily)))
				],
				stamp: stamp
			)
			transcript = transcript.afterReset()
		}

		let memory = Memory(ledger: ledger, clock: clock)
		let context = (try? await memory.context()) ?? ""
		let view =
			(try? await memory.view())
			?? MemoryView(
				sections: [:],
				todayNotes: nil,
				planHeadline: nil,
				orphanNames: []
			)
		let schemas = tools(for: attempt).toolsForTurn(chatId: chatId, memory: view)
		let prefix = PromptAssembly.cyclingPrefix(gated: true)
		let snapshot = try await attempt.training.loadSnapshot(
			clock: clock, attempt: attempt.attempt, diagnostics: diagnostics)
		let language = attempt.language
		let resolution = LanguageResolution(
			language: language.coachReply ?? language.ui,
			source: language.coachReply == nil ? .surface : .preference,
			locale: language.ui.rawValue
		)
		let replyLanguage = PromptAssembly.replyLanguageSection(resolution: resolution)
		let volatile = PromptAssembly.volatile(
			context: context,
			snapshot: snapshot,
			timeZoneName: clock.timeZone.identifier,
			replyLanguage: replyLanguage
		)
		let system = prefix + "\n\n" + volatile
		let history = transcript.history
		let trim = HistoryWindow.trim(
			messages: history.messages, systemTokens: estimateTokens(system),
			ratio: TurnPolicy.historyTokenBudgetRatio)
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
		return TurnPrompt(
			prefix: prefix, system: system, schemas: schemas, timed: timed, summary: summary,
			wire: wire, inTurnRows: transcript.window + [transcript.current].compactMap { $0 })
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

	private func summarize(_ request: String, charge: GenerateCharge, attempt: TurnAttempt)
		async throws -> String
	{
		try await generateStep(
			request: CompletionRequest(
				access: attempt.access,
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

	private func generate(
		_ attempt: TurnAttempt,
		prompt: inout TurnPrompt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws -> AttemptResult {
		try Task.checkCancellation()
		try await scope.chargeAttempt()
		try await scope.checkDeadline(uptime: clock.uptime)
		if prompt.overBudget {
			try await flushOnce(
				.preCompaction, covering: prompt.inTurnRows, attempt: attempt, scope: scope,
				progress: progress)
			try await compact(&prompt, attempt: attempt, scope: scope, progress: progress)
		}
		try await scope.chargeCall()
		var wire = prompt.wire
		var steps = 0
		var lastText = ""
		var lastReason: FinishReason = .stop
		stepLoop: while steps < scope.policy.maxStepsPerInvocation {
			try Task.checkCancellation()
			await progress(.activity(.generating(step: steps + 1)))
			let request = CompletionRequest(
				access: attempt.access,
				attempt: attempt.attempt,
				charge: .chatAttempt,
				messages: [prompt.systemMessage] + prompt.summaryMessages + wire,
				tools: prompt.schemas,
				deadline: await scope.callDeadline(uptime: clock.uptime)
			)
			let step = try await generateStep(request: request, progress: progress)
			steps += 1
			lastText = step.text
			lastReason = step.reason
			if step.reason == .length, step.usage.inputTokens >= TurnPolicy.contextWindowCap {
				throw AttemptFailure.windowExceededFinish
			}
			if step.toolCalls.isEmpty {
				if step.reason == .error || step.reason == .contentFilter,
					step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				{
					throw AttemptFailure.generation(
						step.reason == .error ? .emptyAfterError : .contentFiltered)
				}
				break stepLoop
			}
			wire.append(
				WireMessage(
					role: .assistant, content: step.text, toolCalls: step.toolCalls,
					toolCallId: nil)
			)
			await progress(.activity(.runningTools(step.toolCalls.map(\.name))))
			let outcomes = try await runTools(step.toolCalls, for: attempt, scope: scope)
			for (call, outcome) in outcomes {
				if case .pending(let proposal) = outcome {
					await progress(.proposalPending(proposal))
				}
				wire.append(
					WireMessage(
						role: .tool,
						content: encodeToolOutcome(outcome),
						toolCalls: [],
						toolCallId: call.id
					)
				)
			}
		}

		var assistantText = lastText
		if assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			lastReason == .toolCalls || lastReason == .length
		{
			try await scope.chargeCall()
			let recovery = try await generateStep(
				request: CompletionRequest(
					access: attempt.access,
					attempt: attempt.attempt,
					charge: .stepRecovery,
					messages: [prompt.systemMessage] + prompt.summaryMessages + wire + [
						WireMessage(
							role: .user,
							content: PromptStaticBlocks.recoveryPrompt,
							toolCalls: [],
							toolCallId: nil
						)
					],
					tools: [],
					deadline: await scope.callDeadline(uptime: clock.uptime)
				),
				progress: progress
			)
			assistantText = recovery.text
		}
		if assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			assistantText = PromptStaticBlocks.stepLimitCopy
			await progress(.textDelta(assistantText))
		}

		let templateHash = sha256Hex(
			prompt.prefix + prompt.schemas.map(\.name.rawValue).joined()
				+ attempt.access.model.rawValue)
		let assembledHash = sha256Hex(prompt.system + prompt.timed + assistantText)
		return .replied(
			.model(assistantText),
			lineage: ReplyLineage(templateHash: templateHash, assembledHash: assembledHash)
		)
	}

	private func generateStep(
		request: CompletionRequest,
		progress: @escaping AttemptProgressSink
	) async throws -> GenerateStep {
		let watchdog = ChatWatchdog()
		await watchdog.arm()
		do {
			let step = try await withThrowingTaskGroup(of: GenerateStep.self) { group in
				group.addTask {
					try await self.collect(request: request, watchdog: watchdog, progress: progress)
				}
				group.addTask {
					if let kind = await watchdog.fired() {
						let failure = ProviderFailure.timeout(kind)
						self.diagnostics.record(
							.providerFailure(request.attempt, failure, detail: ""))
						throw failure
					}
					throw CancellationError()
				}
				guard let first = await group.nextResult() else {
					throw CancellationError()
				}
				await watchdog.disarm()
				group.cancelAll()
				while await group.nextResult() != nil {}
				switch first {
				case .success(let step):
					return step
				case .failure(let error):
					throw error
				}
			}
			try Task.checkCancellation()
			return step
		} catch {
			await watchdog.disarm()
			throw error
		}
	}

	private func collect(
		request: CompletionRequest,
		watchdog: ChatWatchdog,
		progress: @escaping AttemptProgressSink
	) async throws -> GenerateStep {
		var text = ""
		var calls: [WireToolCall] = []
		var reason: FinishReason = .stop
		var usage = Usage(inputTokens: 0, outputTokens: 0, cost: nil)
		let stream = transport.stream(request)
		for try await event in stream {
			try Task.checkCancellation()
			switch event {
			case .textDelta(let delta):
				if delta.isEmpty {
					continue
				}
				await watchdog.beat()
				text += delta
				await progress(.textDelta(delta))
			case .toolCall(let call):
				await watchdog.beat()
				calls.append(call)
			case .heartbeat:
				await watchdog.beat()
			case .finished(let finishReason, let finishUsage):
				reason = finishReason
				usage = finishUsage
			}
		}
		return GenerateStep(text: text, toolCalls: calls, reason: reason, usage: usage)
	}

	private func tools(for attempt: TurnAttempt) -> ToolRuntime {
		ToolRuntime(
			intervals: attempt.training.client, ledger: ledger, planning: planning, clock: clock)
	}

	private func runTools(
		_ calls: [WireToolCall],
		for attempt: TurnAttempt,
		scope: TurnScope
	) async throws -> [(WireToolCall, ToolOutcome)] {
		let runtime = tools(for: attempt)
		return try await withThrowingTaskGroup(of: (Int, WireToolCall, ToolOutcome).self) { group in
			for (index, call) in calls.enumerated() {
				group.addTask {
					let arguments =
						(try? JSONValue.parse(call.arguments)) ?? .string(call.arguments)
					let outcome: ToolOutcome
					do {
						outcome = try await runtime.execute(
							name: call.name,
							arguments: arguments,
							chatId: attempt.chat,
							scope: scope
						).outcome
					} catch is CancellationError {
						throw CancellationError()
					} catch {
						self.diagnostics.record(
							.toolFailed(
								scope.stamp.attempt, call.name, detail: String(describing: error)))
						outcome = .result(ToolFault(error).json)
					}
					return (index, call, outcome)
				}
			}
			var rows: [(Int, WireToolCall, ToolOutcome)] = []
			for try await row in group {
				rows.append(row)
			}
			return rows.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
		}
	}

	private func compact(
		_ prompt: inout TurnPrompt,
		attempt: TurnAttempt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws {
		let dropped = Array(prompt.wire.dropLast(min(4, prompt.wire.count)))
		if !dropped.isEmpty {
			await progress(.activity(.compacting))
			try await scope.chargeCall()
			do {
				prompt.summary = try await summarize(
					PromptAssembly.compactionRequest(
						previous: prompt.summary, transcript: PromptAssembly.transcript(dropped)),
					charge: .compaction, attempt: attempt)
				prompt.wire = Array(prompt.wire.suffix(4))
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				diagnostics.record(
					.compactionFailed(attempt.chat, detail: String(describing: error)),
					redacting: [attempt.access.credential.secret])
			}
		}
		if prompt.overBudget {
			throw AttemptFailure.rescueFailed(.windowExceededFinish)
		}
	}

	private func loadTranscript(chatId: ChatID, excluding turn: TurnID) async throws -> Transcript {
		let page = try await ledger.read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: chatId))
		let conversation = ConversationFold.fold(
			chat: chatId, synced: page.records, device: ledger.deviceId)
		let jobs = try await ledger.flushJobs(in: chatId)
		let lastDate: Date?
		switch conversation.lastExchange {
		case .none: lastDate = nil
		case .at(let date): lastDate = date
		}
		return Transcript(
			history: conversation.current.promptHistory(excluding: turn),
			pending: conversation.outstandingRows(jobs),
			unflushed: conversation.messagesSinceLastFlush(jobs, excluding: turn),
			flushPending: jobs.contains { !$0.settled },
			current: conversation.turn(turn)?.userRow,
			lastDate: lastDate
		)
	}

	private func shouldDailyReset(last: Date?) -> Bool {
		guard let last else { return false }
		let resetAt = dailyResetDate(
			now: clock.now, timeZone: clock.timeZone, hour: TurnPolicy.dailyResetHour)
		guard last < resetAt else { return false }
		let grace = TurnPolicy.dailyResetGrace.timeInterval
		if clock.now.timeIntervalSince(last) < grace {
			return false
		}
		return true
	}
}

private struct TurnPrompt: Sendable {
	let prefix: String
	let system: String
	let schemas: [ToolSchema]
	let timed: String
	var summary: String?
	var wire: [WireMessage]
	let inTurnRows: [(ulid: ULID, message: ChatMessage)]

	var systemMessage: WireMessage {
		WireMessage(role: .system, content: system, toolCalls: [], toolCallId: nil)
	}

	var summaryMessages: [WireMessage] {
		guard let summary else { return [] }
		return [
			WireMessage(
				role: .system, content: PromptAssembly.summaryMessage(summary), toolCalls: [],
				toolCallId: nil)
		]
	}

	var estimatedTokens: Int {
		(summaryMessages + wire).reduce(0) { $0 + estimateTokens($1.content) }
			+ estimateTokens(system)
	}

	var overBudget: Bool {
		estimatedTokens > TurnPolicy.contextWindowCap - TurnPolicy.reserveTokens
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

private struct GenerateStep: Sendable {
	var text: String
	var toolCalls: [WireToolCall]
	var reason: FinishReason
	var usage: Usage
}

private func wireMessage(from message: ChatMessage) -> WireMessage {
	WireMessage(
		role: message.role == .user ? .user : .assistant,
		content: message.text,
		toolCalls: [],
		toolCallId: nil
	)
}

private func encodeToolOutcome(_ outcome: ToolOutcome) -> String {
	switch outcome {
	case .result(let json):
		return json.canonicalDigestInput()
	case .pending(let proposal):
		return JSONValue.object([
			"pendingConfirmation": .bool(true),
			"summary": .string(proposal.summary),
		]).canonicalDigestInput()
	case .truncated(let notice, let tokens):
		return JSONValue.object([
			"truncated": .bool(true),
			"notice": .string(notice),
			"omittedSamples": .number(0),
			"estimatedTokens": .number(Double(tokens)),
		]).canonicalDigestInput()
	}
}

private func dailyResetDate(now: Date, timeZone: TimeZone, hour: Int) -> Date {
	var calendar = Calendar(identifier: .gregorian)
	calendar.timeZone = timeZone
	var parts = calendar.dateComponents([.year, .month, .day], from: now)
	parts.hour = hour
	parts.minute = 0
	parts.second = 0
	let todayReset = calendar.date(from: parts) ?? now
	if now < todayReset {
		return calendar.date(byAdding: .day, value: -1, to: todayReset) ?? todayReset
	}
	return todayReset
}
