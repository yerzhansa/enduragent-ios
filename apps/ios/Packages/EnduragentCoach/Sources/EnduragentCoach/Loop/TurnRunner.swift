import Foundation

package struct TurnRunner: Sendable {
	let transport: any ModelTransport
	let intervals: any IntervalsClient
	let store: any RecordLog
	let clock: any Clock
	let tools: ToolRuntime
	let planning: Planning

	package init(
		transport: any ModelTransport,
		intervals: any IntervalsClient,
		store: any RecordLog,
		clock: any Clock,
		tools: ToolRuntime,
		planning: Planning
	) {
		self.transport = transport
		self.intervals = intervals
		self.store = store
		self.clock = clock
		self.tools = tools
		self.planning = planning
	}

	package func run(
		text: String,
		chatId: ChatID,
		language: LanguagePreference,
		emit: @escaping @Sendable (CoachEvent) -> Void
	) async throws {
		_ = planning
		let slash = SlashRouting.parse(text)
		if slash == .plan {
			emit(.finished)
			return
		}
		if slash == .language {
			emit(.languagePicker)
			emit(.finished)
			return
		}

		await tools.beginTurn()
		var writer = RecordWriter(store: store, clock: clock)
		try await writer.refreshClock()

		var transcript = try await loadTranscript(chatId: chatId)
		if shouldDailyReset(last: transcript.lastDate) {
			try await writer.append(
				.flushPending(
					FlushPendingBody(
						chatId: chatId, trigger: .staleReset, messageUlids: transcript.ulids))
			)
			let marker = ULID.generate(at: clock.now)
			try await writer.append(
				.windowStart(WindowStartBody(chatId: chatId, firstIncludedUlid: marker))
			)
			transcript = Transcript(messages: [], ulids: [], lastDate: nil, windowStart: marker)
		}

		let memory = Memory(store: store, clock: clock)
		let context = try await memory.context()
		let view = try await memory.view()
		let schemas = tools.toolsForTurn(chatId: chatId, memory: view)
		let prefix = PromptAssembly.cyclingPrefix(gated: true)
		let snapshot = try await loadSnapshot()
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
			if let first = trim.kept.first, let ulid = transcript.ulid(for: first) {
				try await writer.append(
					.windowStart(WindowStartBody(chatId: chatId, firstIncludedUlid: ulid))
				)
			}
			try await writer.append(
				.compactionSummary(
					CompactionSummaryBody(chatId: chatId, markdown: compactionStub(trim.dropped)))
			)
			try await memory.flush(trigger: .trim, chatId: chatId, transport: transport)
		}
		let kept = trim.kept
		let historyTokens = kept.reduce(0) { $0 + estimateTokens($1.text) }
		let shouldFlush = HistoryWindow.shouldSoftFlush(
			historyTokens: historyTokens,
			budget: trim.budget,
			messagesSinceFlush: kept.count
		)

		let timed = PromptAssembly.appendCurrentTime(
			athleteText: text,
			now: clock.now,
			timeZone: clock.timeZone
		)
		var wire = kept.map(wireMessage(from:))
		wire.append(WireMessage(role: .user, content: timed, toolCalls: [], toolCallId: nil))

		var state = TurnState(
			chatId: chatId,
			messages: kept,
			windowStart: transcript.windowStart,
			pending: nil,
			writesCommitted: 0,
			flushedThisTurn: false,
			lastFlushMessageCount: 0,
			steps: 0
		)

		var budget = TurnBudget.start()
		var streamed = ""
		var overflowTries = 0
		var pendingProposal: PendingProposal?

		attemptLoop: while true {
			try Task.checkCancellation()
			try budget.chargeAttempt()
			try budget.checkDeadline()

			if let remaining = clock.backgroundRemaining, remaining < ChatWatchdog.ttft {
				try await writer.append(
					.flushPending(
						FlushPendingBody(
							chatId: chatId, trigger: .softThreshold, messageUlids: transcript.ulids)
					)
				)
				emit(.interrupted(text: streamed))
				return
			}

			if shouldCompact(wire: wire, system: system) {
				if overflowTries >= TurnPolicy.overflowRetries {
					throw TurnFailure(message: PromptStaticBlocks.compactionFailureCopy)
				}
				try await compact(wire: &wire, budget: &budget, chatId: chatId, writer: &writer)
				overflowTries += 1
			}

			streamed = ""
			pendingProposal = nil
			state.steps = 0
			var lastText = ""
			var lastReason: FinishReason = .stop
			var lastUsage = Usage(inputTokens: 0, outputTokens: 0, cost: nil)

			stepLoop: while state.steps < TurnPolicy.maxSteps {
				try Task.checkCancellation()
				if let remaining = clock.backgroundRemaining, remaining < ChatWatchdog.ttft {
					try await writer.append(
						.flushPending(
							FlushPendingBody(
								chatId: chatId, trigger: .softThreshold,
								messageUlids: transcript.ulids)
						)
					)
					emit(.interrupted(text: streamed))
					return
				}

				try budget.chargeGenerate()
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
				let step: GenerateStep
				do {
					step = try await generateStep(request: request, emit: emit, streamed: &streamed)
				} catch let timeout as WatchdogTimeout {
					emit(
						.failed(
							message: timeout == .ttft
								? "CHAT_TTFT_TIMEOUT" : "CHAT_INTER_CHUNK_TIMEOUT"))
					return
				}

				state.steps += 1
				lastText = step.text
				lastReason = step.reason
				lastUsage = step.usage

				if step.reason == .length, step.usage.inputTokens >= TurnPolicy.contextWindowCap {
					if overflowTries >= TurnPolicy.overflowRetries {
						throw TurnFailure(message: PromptStaticBlocks.compactionFailureCopy)
					}
					overflowTries += 1
					try await compact(wire: &wire, budget: &budget, chatId: chatId, writer: &writer)
					continue attemptLoop
				}

				if step.toolCalls.isEmpty {
					if step.reason == .error || step.reason == .contentFilter,
						step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
					{
						emit(.failed(message: "CHAT_PROVIDER_ERROR"))
						return
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

				let outcomes = try await runTools(
					step.toolCalls, chatId: chatId, state: state, emit: emit)
				for (call, outcome) in outcomes {
					if case .pending(let proposal) = outcome {
						pendingProposal = proposal
						emit(.proposalPending(proposal))
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
					emit: emit,
					streamed: &streamed
				)
				assistantText = recovery.text
			}
			if assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				assistantText = PromptStaticBlocks.stepLimitCopy
				emit(.textDelta(assistantText))
			}

			if !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				let templateHash = sha256Hex(
					prefix + schemas.map(\.name.rawValue).joined()
						+ CompletionRequest.openRouterModel)
				let assembledHash = sha256Hex(system + timed + assistantText)
				try await writer.append(
					.userMessage(
						UserMessageBody(
							chatId: chatId, athleteText: text, timedText: timed, slash: slash)
					)
				)
				try await writer.append(
					.assistantMessage(
						AssistantMessageBody(
							chatId: chatId,
							text: assistantText,
							templateHash: templateHash,
							assembledHash: assembledHash
						)
					)
				)
			}

			if shouldFlush {
				try await writer.append(
					.flushPending(
						FlushPendingBody(
							chatId: chatId, trigger: .softThreshold, messageUlids: transcript.ulids)
					)
				)
			}

			_ = lastUsage
			_ = pendingProposal
			emit(.finished)
			return
		}
	}

}
