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
		var answered = false
		stepLoop: while steps < scope.policy.maxStepsPerInvocation {
			try Task.checkCancellation()
			await progress(.activity(.generating(step: steps + 1)))
			let request = CompletionRequest(
				access: attempt.access,
				attempt: attempt.attempt,
				origin: attempt.origin,
				charge: .chatAttempt,
				messages: [prompt.systemMessage] + prompt.summaryMessages + wire,
				tools: prompt.offer.schemas,
				deadline: await scope.callDeadline(uptime: clock.uptime)
			)
			let step = try await modelCall.run(request: request, progress: progress)
			steps += 1
			lastText = step.text
			lastReason = step.reason
			if step.reason == .length, step.usage.inputTokens >= prompt.window {
				throw AttemptFailure.windowExceededFinish
			}
			if step.toolCalls.isEmpty {
				try step.checkFinish()
				answered = true
				break stepLoop
			}
			wire.append(
				WireMessage(
					role: .assistant, content: step.text, toolCalls: step.toolCalls,
					toolCallId: nil)
			)
			let calls = step.toolCalls.map { call in
				(call, prompt.offer.tool(named: call.name))
			}
			await progress(.activity(.runningTools(calls.compactMap { $0.1?.name })))
			if calls.count(where: { $0.1?.name == .prepareWorkoutChanges }) > 1 {
				await desk.refuseConcurrentPreparations(
					DraftKey(turn: attempt.turn, attempt: attempt.attempt))
			}
			if calls.count(where: { $0.1?.name == .planSave }) > 1 {
				await plans.refuseConcurrentSaves(
					DraftKey(turn: attempt.turn, attempt: attempt.attempt))
			}
			let outcomes = try await runTools(calls, scope: scope)
			for (call, outcome) in outcomes {
				if call.name == ToolName.buildPlanSkeleton.rawValue,
					let draft = PlanDraftStructure(outcome)
				{
					await plans.drafted(
						draft, for: DraftKey(turn: attempt.turn, attempt: attempt.attempt))
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
		if !answered {
			await desk.abandonDraft(DraftKey(turn: attempt.turn, attempt: attempt.attempt))
		}

		var assistantText = lastText
		if assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			lastReason == .toolCalls || lastReason == .length
		{
			try await scope.chargeCall()
			let recovery = try await modelCall.run(
				request: CompletionRequest(
					access: attempt.access,
					attempt: attempt.attempt,
					origin: attempt.origin,
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
		let reply: ReplyText =
			assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			? .catalog(Catalog.coachFallbackStepLimit) : .model(assistantText)
		let templateHash = sha256Hex(
			prompt.prefix + prompt.offer.schemas.map(\.name.rawValue).joined()
				+ attempt.access.model.rawValue)
		let assembledHash = sha256Hex(
			prompt.system + prompt.timed + reply.sentence(in: CatalogPhrasebook(tag: .en)))
		return .replied(
			reply,
			lineage: ReplyLineage(templateHash: templateHash, assembledHash: assembledHash)
		)
	}

	private func runTools(
		_ calls: [(WireToolCall, BoundTool?)],
		scope: TurnScope
	) async throws -> [(WireToolCall, ToolOutcome)] {
		try await withThrowingTaskGroup(of: (Int, WireToolCall, ToolOutcome).self) { group in
			for (index, (call, tool)) in calls.enumerated() {
				group.addTask {
					guard let tool else {
						return (index, call, .result(ToolRuntime.unknownTool))
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
						outcome = try await ToolRuntime.execute(
							tool, arguments: arguments, scope: scope
						).outcome
					} catch is CancellationError {
						throw CancellationError()
					} catch  where Task.isCancelled {
						throw CancellationError()
					} catch {
						self.diagnostics.record(
							.toolFailed(
								scope.stamp.attempt, tool.name, failure: ToolFault(error)))
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
				let summary = try await Compactor(modelCall: modelCall).summarize(
					dropped, previous: prompt.summary, purpose: .inTurn, attempt: attempt)
				prompt.summary = summary.markdown
				prompt.wire = Array(prompt.wire.suffix(4))
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				diagnostics.record(.compactionFailed(attempt.chat, FailureCode(error)))
			}
		}
		if prompt.overBudget {
			throw AttemptFailure.rescueFailed(.windowExceededFinish)
		}
	}
}

func encodeToolOutcome(_ outcome: ToolOutcome) -> String {
	switch outcome {
	case .result(let json):
		return json.canonicalDigestInput()
	case .truncated(let notice, let tokens, let omittedRecords):
		return JSONValue.object([
			"truncated": .bool(true),
			"notice": .string(notice),
			"omittedSamples": .number(Double(omittedRecords)),
			"estimatedTokens": .number(Double(tokens)),
		]).canonicalDigestInput()
	}
}
