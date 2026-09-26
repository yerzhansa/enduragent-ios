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

package struct TurnAttempt: Sendable, Equatable {
	package let turn: TurnID
	package let attempt: AttemptID
	package let chat: ChatID
	package let request: String
	package let slash: SlashCommand?
	package let language: LanguagePreference
	package let access: ResolvedAccess
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

package struct AttemptReport: Sendable, Equatable {
	package let result: AttemptResult
	package let softFlushDue: Bool
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
	private let intervals: any IntervalsClient
	private let ledger: Ledger
	private let clock: any Clock
	private let tools: ToolRuntime
	private let planning: Planning
	private let diagnostics: DiagnosticsLog
	private let ladder: RetryLadder

	package init(
		transport: any ModelTransport,
		intervals: any IntervalsClient,
		ledger: Ledger,
		clock: any Clock,
		tools: ToolRuntime,
		planning: Planning,
		diagnostics: DiagnosticsLog,
		ladder: RetryLadder
	) {
		self.transport = transport
		self.intervals = intervals
		self.ledger = ledger
		self.clock = clock
		self.tools = tools
		self.planning = planning
		self.diagnostics = diagnostics
		self.ladder = ladder
	}

	package func run(
		_ attempt: TurnAttempt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws(CancellationError) -> AttemptReport {
		let prompt: TurnPrompt
		do {
			prompt = try await assemble(attempt, scope: scope, progress: progress)
		} catch {
			let failure = try AttemptFailure(caught: error)
			return AttemptReport(
				result: .failed(
					failure.coachFailure(for: attempt.access.method),
					saved: WriteSummary(await scope.written)),
				softFlushDue: false
			)
		}
		return try await attempts(attempt, prompt: prompt, scope: scope, progress: progress)
	}

	private func attempts(
		_ attempt: TurnAttempt,
		prompt initial: TurnPrompt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws(CancellationError) -> AttemptReport {
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
				let saved = WriteSummary(await scope.written)
				switch ladder.decide(failure, situation: situation, counters: counters) {
				case .terminal(let coachFailure):
					return AttemptReport(
						result: .failed(coachFailure, saved: saved), softFlushDue: false)
				case .settleSavedWork(let outcome):
					return AttemptReport(
						result: .savedWork(outcome, saved: saved), softFlushDue: false)
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
				try await flushOnce(trigger, attempt: attempt, scope: scope, progress: progress)
			case .compactInTurn:
				do {
					try await compact(&prompt, attempt: attempt, scope: scope, progress: progress)
				} catch is CancellationError {
					throw CancellationError()
				} catch {
					diagnostics.record(
						.compactionFailed(attempt.chat, detail: String(describing: error)),
						redacting: [attempt.access.credential.secret])
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
		attempt: TurnAttempt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws {
		guard await scope.takeFlushLatch() else { return }
		await progress(.activity(.savingMemory))
		do {
			try await Memory(ledger: ledger, clock: clock).flush(
				trigger: trigger, chatId: attempt.chat, transport: transport, access: attempt.access
			)
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			diagnostics.record(
				.memoryFlushFailed(attempt.chat, detail: String(describing: error)),
				redacting: [attempt.access.credential.secret])
		}
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
			_ = try await ledger.commit(
				local: [
					.flushPending(
						FlushPendingBody(
							chatId: chatId, trigger: .staleReset, messageUlids: transcript.ulids))
				],
				stamp: stamp
			)
			let marker = await ledger.nextULID()
			_ = try await ledger.commit(
				synced: [
					.windowStart(
						WindowStartBody(
							chatId: chatId, firstIncludedUlid: marker, reason: .reset(.daily)))
				],
				stamp: stamp
			)
			transcript = Transcript(messages: [], ulids: [], lastDate: nil)
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
		let schemas = tools.toolsForTurn(chatId: chatId, memory: view)
		let prefix = PromptAssembly.cyclingPrefix(gated: true)
		let snapshot = await loadSnapshot()
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
		let systemTokens = estimateTokens(system)
		let trim = HistoryWindow.trim(messages: transcript.messages, systemTokens: systemTokens)
		if !trim.dropped.isEmpty {
			var bodies: [SyncedRecordBody] = []
			if let first = trim.kept.first, let ulid = transcript.ulid(for: first) {
				bodies.append(
					.windowStart(
						WindowStartBody(chatId: chatId, firstIncludedUlid: ulid, reason: .trim)))
			}
			bodies.append(
				.compactionSummary(
					CompactionSummaryBody(chatId: chatId, markdown: compactionStub(trim.dropped))))
			_ = try await ledger.commit(synced: bodies, stamp: stamp)
			try await flushOnce(.trim, attempt: attempt, scope: scope, progress: progress)
		}
		let kept = trim.kept
		let historyTokens = kept.reduce(0) { $0 + estimateTokens($1.text) }
		let softFlushDue = HistoryWindow.shouldSoftFlush(
			historyTokens: historyTokens,
			budget: trim.budget,
			messagesSinceFlush: kept.count
		)

		let timed = PromptAssembly.appendCurrentTime(
			athleteText: attempt.request,
			now: clock.now,
			timeZone: clock.timeZone
		)
		var wire = kept.map(wireMessage(from:))
		wire.append(WireMessage(role: .user, content: timed, toolCalls: [], toolCallId: nil))
		return TurnPrompt(
			prefix: prefix, system: system, schemas: schemas, timed: timed,
			softFlushDue: softFlushDue, wire: wire)
	}

	private func generate(
		_ attempt: TurnAttempt,
		prompt: inout TurnPrompt,
		scope: TurnScope,
		progress: @escaping AttemptProgressSink
	) async throws -> AttemptReport {
		try Task.checkCancellation()
		try await scope.chargeAttempt()
		try await scope.checkDeadline(uptime: clock.uptime)
		if prompt.overBudget {
			try await flushOnce(.preCompaction, attempt: attempt, scope: scope, progress: progress)
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
				messages: [prompt.systemMessage] + wire,
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
			let outcomes = try await runTools(step.toolCalls, chatId: attempt.chat, scope: scope)
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
					messages: [prompt.systemMessage] + wire + [
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
		return AttemptReport(
			result: .replied(
				.model(assistantText),
				lineage: ReplyLineage(templateHash: templateHash, assembledHash: assembledHash)
			),
			softFlushDue: prompt.softFlushDue
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

	private func runTools(
		_ calls: [WireToolCall],
		chatId: ChatID,
		scope: TurnScope
	) async throws -> [(WireToolCall, ToolOutcome)] {
		try await withThrowingTaskGroup(of: (Int, WireToolCall, ToolOutcome).self) { group in
			for (index, call) in calls.enumerated() {
				group.addTask {
					let arguments =
						(try? JSONValue.parse(call.arguments)) ?? .string(call.arguments)
					let outcome: ToolOutcome
					do {
						outcome = try await self.tools.execute(
							name: call.name,
							arguments: arguments,
							chatId: chatId,
							scope: scope
						).outcome
					} catch is CancellationError {
						throw CancellationError()
					} catch {
						outcome = .result(.object(["error": .string(toolErrorText(error))]))
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
		await progress(.activity(.compacting))
		try await scope.chargeCall()
		let chatId = attempt.chat
		let keep = Array(prompt.wire.suffix(4))
		let dropped = Array(prompt.wire.dropLast(min(4, prompt.wire.count)))
		let request = CompletionRequest(
			access: attempt.access,
			attempt: attempt.attempt,
			charge: .compaction,
			messages: [
				WireMessage(
					role: .system,
					content:
						"Summarize the conversation. Required headings: ## Athlete Profile, ## Training Status, ## Coach Stance, ## Discussion Context, ## Pending Questions.",
					toolCalls: [],
					toolCallId: nil
				),
				WireMessage(
					role: .user,
					content: dropped.map(\.content).joined(separator: "\n"),
					toolCalls: [],
					toolCallId: nil
				),
			],
			tools: [],
			deadline: TurnPolicy.compactionTimeout
		)
		let summary: String
		do {
			summary = try await generateStep(request: request, progress: { _ in }).text
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			summary = compactionStub(
				dropped.map { ChatMessage(role: .user, text: $0.content, civilDate: nil) })
		}
		var bodies: [SyncedRecordBody] = []
		if !keep.isEmpty {
			bodies.append(
				.windowStart(
					WindowStartBody(
						chatId: chatId,
						firstIncludedUlid: await ledger.nextULID(),
						reason: .compaction
					)
				)
			)
		}
		bodies.append(.compactionSummary(CompactionSummaryBody(chatId: chatId, markdown: summary)))
		_ = try await ledger.commit(synced: bodies, stamp: scope.stamp)
		var next: [WireMessage] = [
			WireMessage(
				role: .system,
				content: "[Previous conversation summary]\n\(summary)",
				toolCalls: [],
				toolCallId: nil
			)
		]
		next.append(contentsOf: keep)
		prompt.wire = next
	}

	private func loadSnapshot() async -> AthleteSnapshot? {
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		let oldest = today.adding(days: -(7 - 1))
		guard let days = try? await intervals.fetchWellness(oldest: oldest, newest: today) else {
			return nil
		}
		guard let latest = days.last else {
			return nil
		}
		return AthleteSnapshot(fitness: latest.fitness, fatigue: latest.fatigue, form: latest.form)
	}

	private func loadTranscript(chatId: ChatID, excluding turn: TurnID) async throws -> Transcript {
		let page = try await ledger.read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: chatId))
		let conversation = ConversationFold.fold(
			chat: chatId, synced: page.records, device: ledger.deviceId)
		let history = conversation.current.promptHistory(excluding: turn)
		let lastDate: Date?
		switch conversation.lastExchange {
		case .none: lastDate = nil
		case .at(let date): lastDate = date
		}
		return Transcript(messages: history.messages, ulids: history.ulids, lastDate: lastDate)
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
	let softFlushDue: Bool
	var wire: [WireMessage]

	var systemMessage: WireMessage {
		WireMessage(role: .system, content: system, toolCalls: [], toolCallId: nil)
	}

	var estimatedTokens: Int {
		wire.reduce(0) { $0 + estimateTokens($1.content) } + estimateTokens(system)
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

private struct Transcript: Sendable {
	var messages: [ChatMessage]
	var ulids: [ULID]
	var lastDate: Date?

	func ulid(for message: ChatMessage) -> ULID? {
		guard let index = messages.firstIndex(of: message) else { return nil }
		return ulids[index]
	}
}

private func toolErrorText(_ error: any Error) -> String {
	if let intervals = error as? IntervalsError {
		return intervals.details
	}
	if let workout = error as? InvalidWorkout {
		return workout.message
	}
	return String(describing: error)
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

private func compactionStub(_ dropped: [ChatMessage]) -> String {
	"""
	## Athlete Profile
	## Training Status
	## Coach Stance
	## Discussion Context
	\(dropped.map(\.text).joined(separator: "\n"))
	## Pending Questions
	"""
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
