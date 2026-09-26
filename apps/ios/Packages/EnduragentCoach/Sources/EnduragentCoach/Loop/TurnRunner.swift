import Foundation

package struct AttemptContext: Sendable, Equatable {
	package var chatId: ChatID
	package var messages: [ChatMessage]
	package var windowStart: ULID?
	package var pending: ProposalBody?
	package var writesCommitted: Int
	package var flushedThisTurn: Bool
	package var lastFlushMessageCount: Int
	package var steps: Int
	package var stamp: OperationStamp
}

public enum TurnPolicy {
	public static let maxSteps = 10
	public static let maxGenerateCalls = 40
	public static let maxAttempts = 4
	public static let wallClock: Duration = .seconds(10 * 60)
	public static let chatCallDeadline: Duration = .seconds(600)
	public static let compactionTimeout: Duration = .seconds(120)
	public static let toolResultTokenCap = 24_000
	public static let athleteContextChars = 20_000
	public static let historyBudgetFloor = 8_000
	public static let historyTokenBudgetRatio = 0.3
	public static let contextWindowCap = 200_000
	public static let overflowRetries = 3
	public static let dailyResetHour = 4
	public static let dailyResetGrace: Duration = .seconds(30 * 60)
	public static let proposalTTL: Duration = .seconds(10 * 60)
	public static let ungatedPrefixTokenCeiling = 13_200
	public static let gatedPrefixTokenCeiling = 13_600
}

public struct TurnBudgetExceeded: Error, Equatable, Sendable {
	public var kind: Kind

	public enum Kind: String, Sendable, Equatable {
		case generateCalls
		case generateAttempts
		case wallClock
	}
}

public struct TurnBudget: Sendable {
	public var generatesRemaining: Int
	public var attemptsRemaining: Int
	public var deadline: ContinuousClock.Instant

	public static func start(clock: ContinuousClock = ContinuousClock()) -> TurnBudget {
		TurnBudget(
			generatesRemaining: TurnPolicy.maxGenerateCalls,
			attemptsRemaining: TurnPolicy.maxAttempts,
			deadline: clock.now.advanced(by: TurnPolicy.wallClock)
		)
	}

	public mutating func chargeGenerate() throws {
		guard generatesRemaining > 0 else {
			throw TurnBudgetExceeded(kind: .generateCalls)
		}
		generatesRemaining -= 1
	}

	public mutating func chargeAttempt() throws {
		guard attemptsRemaining > 0 else {
			throw TurnBudgetExceeded(kind: .generateAttempts)
		}
		attemptsRemaining -= 1
	}

	public func remaining(until now: ContinuousClock.Instant) -> Duration {
		now < deadline ? deadline - now : .zero
	}

	public func checkDeadline(now: ContinuousClock.Instant = ContinuousClock().now) throws {
		if now >= deadline {
			throw TurnBudgetExceeded(kind: .wallClock)
		}
	}
}

package struct TurnAttempt: Sendable, Equatable {
	package let turn: TurnID
	package let attempt: AttemptID
	package let chat: ChatID
	package let request: String
	package let slash: SlashCommand?
	package let language: LanguagePreference
}

package enum AttemptProgress: Sendable, Equatable {
	case textDelta(String)
	case attemptRestarted
	case activity(TurnActivity)
	case proposalPending(PendingProposal)
}

package enum AttemptResult: Sendable, Equatable {
	case replied(ReplyText, lineage: ReplyLineage)
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

	package init(
		transport: any ModelTransport,
		intervals: any IntervalsClient,
		ledger: Ledger,
		clock: any Clock,
		tools: ToolRuntime,
		planning: Planning
	) {
		self.transport = transport
		self.intervals = intervals
		self.ledger = ledger
		self.clock = clock
		self.tools = tools
		self.planning = planning
	}

	package func run(
		_ attempt: TurnAttempt,
		progress: @escaping AttemptProgressSink
	) async throws(CancellationError) -> AttemptReport {
		do {
			return try await perform(attempt, progress: progress)
		} catch is CancellationError {
			throw CancellationError()
		} catch is LedgerFailure {
			return AttemptReport(
				result: .failed(.local(.recordStorage), saved: .none), softFlushDue: false)
		} catch let budget as TurnBudgetExceeded {
			return failed(.budgetExhausted(budget.kind))
		} catch is WatchdogTimeout {
			return failed(.providerDown(.timeout))
		} catch is UnknownFinishReasonError {
			return failed(.generationFailed(.unknownFinish))
		} catch is OpenRouterParseError {
			return failed(.generationFailed(.malformedStream))
		} catch is URLError {
			return failed(.providerDown(.network))
		} catch {
			return failed(.providerDown(.outage))
		}
	}

	private func failed(_ failure: ModelFailure) -> AttemptReport {
		AttemptReport(result: .failed(.model(failure), saved: .none), softFlushDue: false)
	}

	private func perform(
		_ attempt: TurnAttempt,
		progress: @escaping AttemptProgressSink
	) async throws -> AttemptReport {
		_ = planning
		let chatId = attempt.chat
		let stamp = OperationStamp(
			operation: .turn(attempt.turn),
			attempt: attempt.attempt,
			binding: ActionBinding(
				account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
		)
		await tools.beginTurn()

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
			transcript = Transcript(messages: [], ulids: [], lastDate: nil, windowStart: marker)
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
			await progress(.activity(.savingMemory))
			try? await memory.flush(trigger: .trim, chatId: chatId, transport: transport)
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

		var state = AttemptContext(
			chatId: chatId,
			messages: kept,
			windowStart: transcript.windowStart,
			pending: nil,
			writesCommitted: 0,
			flushedThisTurn: false,
			lastFlushMessageCount: 0,
			steps: 0,
			stamp: stamp
		)

		var budget = TurnBudget.start()
		var overflowTries = 0
		var first = true

		attemptLoop: while true {
			try Task.checkCancellation()
			try budget.chargeAttempt()
			try budget.checkDeadline()
			if !first {
				await progress(.attemptRestarted)
			}
			first = false

			if shouldCompact(wire: wire, system: system) {
				if overflowTries >= TurnPolicy.overflowRetries {
					return AttemptReport(
						result: .failed(.model(.contextOverflow), saved: .none), softFlushDue: false
					)
				}
				await progress(.activity(.compacting))
				try await compact(wire: &wire, budget: &budget, chatId: chatId, stamp: stamp)
				overflowTries += 1
			}

			state.steps = 0
			var lastText = ""
			var lastReason: FinishReason = .stop

			stepLoop: while state.steps < TurnPolicy.maxSteps {
				try Task.checkCancellation()
				try budget.chargeGenerate()
				await progress(.activity(.generating(step: state.steps + 1)))
				let deadline = minDuration(
					TurnPolicy.chatCallDeadline,
					budget.remaining(until: ContinuousClock().now)
				)
				var messages = [
					WireMessage(role: .system, content: system, toolCalls: [], toolCallId: nil)
				]
				messages.append(contentsOf: wire)
				let request = CompletionRequest.openRouter(
					messages: messages,
					tools: schemas,
					deadline: deadline
				)
				let step = try await generateStep(request: request, progress: progress)

				state.steps += 1
				lastText = step.text
				lastReason = step.reason

				if step.reason == .length, step.usage.inputTokens >= TurnPolicy.contextWindowCap {
					if overflowTries >= TurnPolicy.overflowRetries {
						return AttemptReport(
							result: .failed(.model(.contextOverflow), saved: .none),
							softFlushDue: false)
					}
					overflowTries += 1
					await progress(.activity(.compacting))
					try await compact(wire: &wire, budget: &budget, chatId: chatId, stamp: stamp)
					continue attemptLoop
				}

				if step.toolCalls.isEmpty {
					if step.reason == .error || step.reason == .contentFilter,
						step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
					{
						let fault: GenerationFault =
							step.reason == .error ? .emptyAfterError : .contentFiltered
						return AttemptReport(
							result: .failed(.model(.generationFailed(fault)), saved: .none),
							softFlushDue: false)
					}
					break stepLoop
				}

				let ids = Set(step.toolCalls.map(\.id))
				let watchdogPause = ChatWatchdog()
				await watchdogPause.pauseForTools(ids)
				wire.append(
					WireMessage(
						role: .assistant, content: step.text, toolCalls: step.toolCalls,
						toolCallId: nil)
				)

				await progress(.activity(.runningTools(step.toolCalls.map(\.name))))
				let outcomes = try await runTools(step.toolCalls, chatId: chatId, state: state)
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
				await watchdogPause.pauseForTools([])
				await watchdogPause.disarm()

				if state.steps == TurnPolicy.maxSteps {
					break stepLoop
				}
			}

			var assistantText = lastText
			if assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
				lastReason == .toolCalls || lastReason == .length
			{
				try budget.chargeGenerate()
				let recovery = try await generateStep(
					request: CompletionRequest.openRouter(
						messages: [
							WireMessage(
								role: .system, content: system, toolCalls: [], toolCallId: nil)
						] + wire + [
							WireMessage(
								role: .user,
								content: PromptStaticBlocks.recoveryPrompt,
								toolCalls: [],
								toolCallId: nil
							)
						],
						tools: [],
						deadline: minDuration(
							TurnPolicy.chatCallDeadline,
							budget.remaining(until: ContinuousClock().now)
						)
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
				prefix + schemas.map(\.name.rawValue).joined() + CompletionRequest.openRouterModel)
			let assembledHash = sha256Hex(system + timed + assistantText)
			return AttemptReport(
				result: .replied(
					.model(assistantText),
					lineage: ReplyLineage(templateHash: templateHash, assembledHash: assembledHash)
				),
				softFlushDue: softFlushDue
			)
		}
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
						throw kind
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
		state: AttemptContext
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
							state: state
						)
					} catch is CancellationError {
						throw CancellationError()
					} catch {
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
		wire: inout [WireMessage],
		budget: inout TurnBudget,
		chatId: ChatID,
		stamp: OperationStamp
	) async throws {
		try budget.chargeGenerate()
		let keep = Array(wire.suffix(4))
		let dropped = Array(wire.dropLast(min(4, wire.count)))
		let request = CompletionRequest.openRouter(
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
		_ = try await ledger.commit(synced: bodies, stamp: stamp)
		var next: [WireMessage] = [
			WireMessage(
				role: .system,
				content: "[Previous conversation summary]\n\(summary)",
				toolCalls: [],
				toolCallId: nil
			)
		]
		next.append(contentsOf: keep)
		wire = next
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
		return Transcript(
			messages: history.messages,
			ulids: history.ulids,
			lastDate: lastDate,
			windowStart: conversation.current.promptWindow.firstIncluded
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
	var windowStart: ULID?

	func ulid(for message: ChatMessage) -> ULID? {
		guard let index = messages.firstIndex(of: message) else { return nil }
		return ulids[index]
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

private func shouldCompact(wire: [WireMessage], system: String) -> Bool {
	let estimated = wire.reduce(0) { $0 + estimateTokens($1.content) } + estimateTokens(system)
	let budget = TurnPolicy.contextWindowCap - 20_000
	return estimated > budget
}

private func minDuration(_ lhs: Duration, _ rhs: Duration) -> Duration {
	lhs < rhs ? lhs : rhs
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
