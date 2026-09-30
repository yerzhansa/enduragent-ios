import Foundation

extension TurnRunner {
	func generate(
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
				covering: prompt.inTurnRows, attempt: attempt, scope: scope,
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
			if step.reason == .length, step.usage.inputTokens >= prompt.window {
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
			let calls = step.toolCalls.map { call in
				(call, prompt.schemas.first { $0.name.rawValue == call.name }?.name)
			}
			await progress(.activity(.runningTools(calls.compactMap { $0.1 })))
			let outcomes = try await runTools(calls, for: attempt, scope: scope)
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

		if let outcome = await scope.savedReviewWork() {
			return .savedWork(outcome, saved: await scope.summary)
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

	func generateStep(
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
		_ calls: [(WireToolCall, ToolName?)],
		for attempt: TurnAttempt,
		scope: TurnScope
	) async throws -> [(WireToolCall, ToolOutcome)] {
		let runtime = tools(for: attempt)
		return try await withThrowingTaskGroup(of: (Int, WireToolCall, ToolOutcome).self) { group in
			for (index, (call, name)) in calls.enumerated() {
				group.addTask {
					guard let name else {
						return (
							index, call,
							.result(
								.object([
									"error": .string("unknown_tool"),
									"details": .string(
										"This tool was not offered for this turn. Use an offered tool."
									),
								]))
						)
					}
					let arguments: JSONValue
					do {
						arguments = try call.parseArguments()
					} catch is DecodingError {
						return (
							index, call,
							.result(
								.object([
									"details": .string("Tool arguments were not valid JSON."),
									"error": .string("invalid_arguments"),
								])
							)
						)
					}
					let outcome: ToolOutcome
					do {
						outcome = try await runtime.execute(
							name: name,
							arguments: arguments,
							chatId: attempt.chat,
							scope: scope
						).outcome
					} catch let saved as SavedWorkReached {
						throw saved
					} catch is CancellationError {
						throw CancellationError()
					} catch  where Task.isCancelled {
						throw CancellationError()
					} catch {
						self.diagnostics.record(
							.toolFailed(
								scope.stamp.attempt, name, failure: ToolFault(error)))
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

	func compact(
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
}

struct GenerateStep: Sendable {
	var text: String
	var toolCalls: [WireToolCall]
	var reason: FinishReason
	var usage: Usage
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
