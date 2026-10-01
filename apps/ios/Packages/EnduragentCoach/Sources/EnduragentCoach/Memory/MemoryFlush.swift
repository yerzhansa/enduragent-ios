import Foundation

extension Memory {
	package func runFlush(
		messages: [ChatMessage],
		access: ResolvedAccess,
		transport: any ModelTransport,
		diagnostics: DiagnosticsLog,
		ladder: RetryLadder,
		stamp: OperationStamp,
		scope: TurnScope?
	) async throws(CancellationError) -> FlushOutcome {
		guard !messages.isEmpty else { return .nothingToSave }
		let run = FlushRun(
			messages: messages, timeZone: clock.timeZone, access: access, transport: transport,
			stamp: stamp, diagnostics: diagnostics, ladder: ladder,
			maxAttempts: (scope?.policy ?? .npm).maxGenerateAttempts)
		var tally = FlushTally()
		do {
			try await runFlushGenerate(run, scope: scope, tally: &tally)
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			let failure = try AttemptFailure(caught: error).coachFailure(for: access.method)
			if tally.isEmpty {
				return .failed(failure)
			}
			return .partial(sections: tally.sections, events: tally.events, failure: failure)
		}
		if tally.isEmpty {
			return .nothingToSave
		}
		return .saved(sections: tally.sections, events: tally.events)
	}

	private func runFlushGenerate(_ run: FlushRun, scope: TurnScope?, tally: inout FlushTally)
		async throws
	{
		try await scope?.chargeCall()
		let current = try await fullContext()
		let today = IntervalsPolicy.today(now: clock.now, timeZone: run.timeZone)
		let fenced = PromptAssembly.wrapAthleteContext(
			current.isEmpty ? "No athlete data stored yet." : current)
		var messages: [WireMessage] = [
			WireMessage(
				role: .system, content: MemoryFlushPrompt.system, toolCalls: [], toolCallId: nil)
		]
		messages.append(
			contentsOf: run.messages.map { PromptAssembly.wireMessage(from: $0) })
		messages.append(
			WireMessage(
				role: .user,
				content: MemoryFlushPrompt.userPrompt(
					sections: SectionName.cyclingEffective,
					currentMemory: fenced,
					today: today.rawValue
				),
				toolCalls: [],
				toolCallId: nil
			)
		)
		let schemas = MemoryFlushPrompt.toolSchemas()
		var steps = 0
		var counters = RetryCounters.zero
		var attempts = 1
		var remainingRetryWait = MemoryFlushPolicy.retryWaitAllowance
		let modelCall = ModelCall(transport: run.transport, diagnostics: run.diagnostics)
		while steps < MemoryFlushPolicy.maxSteps {
			try Task.checkCancellation()
			try await scope?.checkDeadline(uptime: clock.uptime)
			let request = CompletionRequest(
				access: run.access,
				attempt: run.stamp.attempt,
				charge: .memoryFlush,
				messages: messages,
				tools: schemas,
				deadline: await scope?.callDeadline(uptime: clock.uptime)
					?? TurnBudgetPolicy.npm.perCallDeadline
			)
			let step: GenerateStep
			do {
				step = try await modelCall.run(request: request)
			} catch {
				let failure = try AttemptFailure(caught: error)
				let situation = AttemptSituation(
					committed: [], observedText: false,
					promptTokens: messages.reduce(0) { $0 + estimateTokens($1.content) },
					effectiveWindow: TurnPolicy.contextWindowCap, flushLatchFree: false,
					accessMethod: run.access.method, jitter: Double.random(in: 0..<1))
				guard attempts < run.maxAttempts,
					case .retry(let next, let preparations) = run.ladder.decide(
						failure, situation: situation, counters: counters)
				else { throw failure }
				for preparation in preparations {
					switch preparation {
					case .wait(let duration, _):
						guard duration <= remainingRetryWait else {
							throw failure
						}
						try await clock.sleep(for: duration)
						remainingRetryWait -= duration
					case .flushMemory, .compactInTurn:
						throw failure
					}
				}
				counters = next
				attempts += 1
				try await scope?.chargeCall()
				continue
			}
			steps += 1
			try Task.checkCancellation()
			if step.toolCalls.isEmpty {
				try step.checkFinish()
				break
			}
			messages.append(
				WireMessage(
					role: .assistant, content: step.text, toolCalls: step.toolCalls, toolCallId: nil
				)
			)
			for call in step.toolCalls {
				let execution: ToolExecution
				do {
					let arguments = try call.parseArguments()
					switch ToolName(rawValue: call.name) {
					case .memoryWrite:
						execution = try await executeMemoryWrite(
							arguments, source: .flush, stamp: run.stamp)
					case .ledgerAppend:
						execution = try await executeLedgerAppend(
							arguments, source: .flush, stamp: run.stamp)
					default:
						execution = .result(.object(["error": .string("unsupported")]))
					}
				} catch is DecodingError {
					execution = .result(.object(["error": .string("invalid_arguments")]))
				}
				if execution.commit?.tool == .memoryWrite { tally.sections += 1 }
				if execution.commit?.tool == .ledgerAppend { tally.events += 1 }
				messages.append(
					WireMessage(
						role: .tool, content: encodeToolOutcome(execution.outcome), toolCalls: [],
						toolCallId: call.id)
				)
			}
		}
	}

}

private struct FlushRun: Sendable {
	let messages: [ChatMessage]
	let timeZone: TimeZone
	let access: ResolvedAccess
	let transport: any ModelTransport
	let stamp: OperationStamp
	let diagnostics: DiagnosticsLog
	let ladder: RetryLadder
	let maxAttempts: Int
}

private struct FlushTally {
	var sections = 0
	var events = 0

	var isEmpty: Bool {
		sections == 0 && events == 0
	}
}
