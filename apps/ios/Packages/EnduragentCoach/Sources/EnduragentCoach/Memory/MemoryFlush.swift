import Foundation

extension Memory {
	package func runFlush(
		_ job: FlushJob,
		messages: [ChatMessage],
		access: ResolvedAccess,
		transport: any ModelTransport,
		stamp: OperationStamp,
		scope: TurnScope?
	) async throws(CancellationError) -> FlushOutcome {
		guard !messages.isEmpty else { return .nothingToSave }
		let run = FlushRun(messages: messages, access: access, transport: transport, stamp: stamp)
		var tally = FlushTally()
		do {
			try await flushRetryingFailures(run, scope: scope, tally: &tally)
			if job.trigger == .staleReset, tally.isEmpty,
				messages.count >= MemoryFlushPolicy.flushZeroWriteMinMessages
			{
				try await flushRetryingFailures(run, scope: scope, tally: &tally)
			}
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

	private func flushRetryingFailures(
		_ run: FlushRun, scope: TurnScope?, tally: inout FlushTally
	) async throws {
		var attempt = 1
		while true {
			do {
				try await runFlushGenerate(run, scope: scope, tally: &tally)
				return
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				guard attempt < MemoryFlushPolicy.maxAttempts else { throw error }
				attempt += 1
			}
		}
	}

	private func runFlushGenerate(_ run: FlushRun, scope: TurnScope?, tally: inout FlushTally)
		async throws
	{
		try await scope?.chargeCall()
		let current = try await fullContext()
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		let fenced = PromptAssembly.wrapAthleteContext(
			current.isEmpty ? "No athlete data stored yet." : current)
		var messages: [WireMessage] = [
			WireMessage(
				role: .system, content: MemoryFlushPrompt.system, toolCalls: [], toolCallId: nil)
		]
		messages.append(contentsOf: run.messages.map(memoryWireMessage(from:)))
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
		while steps < MemoryFlushPolicy.maxSteps {
			steps += 1
			let request = CompletionRequest(
				access: run.access,
				attempt: run.stamp.attempt,
				charge: .memoryFlush,
				messages: messages,
				tools: schemas,
				deadline: TurnBudgetPolicy.npm.perCallDeadline
			)
			let step = try await collectFlush(transport: run.transport, request: request)
			try Task.checkCancellation()
			if step.calls.isEmpty {
				break
			}
			messages.append(
				WireMessage(
					role: .assistant, content: step.text, toolCalls: step.calls, toolCallId: nil)
			)
			for call in step.calls {
				let (payload, wroteSection, wroteLedger) = try await executeFlushTool(
					call, stamp: run.stamp)
				if wroteSection { tally.sections += 1 }
				if wroteLedger { tally.events += 1 }
				messages.append(
					WireMessage(role: .tool, content: payload, toolCalls: [], toolCallId: call.id)
				)
			}
		}
	}

	private func collectFlush(
		transport: any ModelTransport,
		request: CompletionRequest
	) async throws -> (text: String, calls: [WireToolCall], reason: FinishReason) {
		var text = ""
		var calls: [WireToolCall] = []
		var reason: FinishReason = .stop
		for try await event in transport.stream(request) {
			switch event {
			case .textDelta(let delta):
				text += delta
			case .toolCall(let call):
				calls.append(call)
			case .heartbeat:
				break
			case .finished(let finishReason, _):
				reason = finishReason
			}
		}
		_ = reason
		return (text, calls, reason)
	}

	private func executeFlushTool(_ call: WireToolCall, stamp: OperationStamp) async throws -> (
		String, Bool, Bool
	) {
		let arguments: JSONValue
		do {
			arguments = try JSONValue.parse(call.arguments)
		} catch {
			return (
				JSONValue.object(["error": .string("invalid_arguments")]).canonicalDigestInput(),
				false, false
			)
		}
		switch call.name {
		case .memoryWrite:
			let fields = arguments.objectFields
			guard let section = fields["section"]?.stringValue,
				let content = fields["content"]?.stringValue
			else {
				return (
					JSONValue.object(["error": .string("section_required")]).canonicalDigestInput(),
					false, false
				)
			}
			try await writeSection(
				SectionName(rawValue: section), content: content, source: .flush, stamp: stamp)
			return (JSONValue.object(["saved": .bool(true)]).canonicalDigestInput(), true, false)
		case .ledgerAppend:
			let fields = arguments.objectFields
			guard
				let dateRaw = fields["date"]?.stringValue,
				let date = CivilDate(rawValue: dateRaw),
				let kindRaw = fields["kind"]?.stringValue,
				let kind = LedgerKind(rawValue: kindRaw),
				let text = fields["text"]?.stringValue,
				!text.isEmpty
			else {
				return (
					JSONValue.object(["error": .string("invalid_event")]).canonicalDigestInput(),
					false,
					false
				)
			}
			let recorded = try await appendEvent(
				date: date, kind: kind, text: text, source: .flush, stamp: stamp)
			if recorded {
				return (
					JSONValue.object(["recorded": .bool(true)]).canonicalDigestInput(), false, true
				)
			}
			return (
				JSONValue.object(["duplicate": .bool(true), "recorded": .bool(false)])
					.canonicalDigestInput(),
				false,
				false
			)
		default:
			return (
				JSONValue.object(["error": .string("unsupported")]).canonicalDigestInput(), false,
				false
			)
		}
	}
}

private struct FlushRun: Sendable {
	let messages: [ChatMessage]
	let access: ResolvedAccess
	let transport: any ModelTransport
	let stamp: OperationStamp
}

private struct FlushTally {
	var sections = 0
	var events = 0

	var isEmpty: Bool {
		sections == 0 && events == 0
	}
}

private func memoryWireMessage(from message: ChatMessage) -> WireMessage {
	WireMessage(
		role: message.role == .user ? .user : .assistant,
		content: message.text,
		toolCalls: [],
		toolCallId: nil
	)
}
