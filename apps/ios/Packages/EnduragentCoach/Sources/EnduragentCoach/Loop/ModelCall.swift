import Foundation

extension TurnRunner {
	var modelCall: ModelCall {
		ModelCall(
			transport: transport, diagnostics: diagnostics, watchdogSleep: watchdogSleep,
			authorizeInvocation: authorizeInvocation)
	}
}

struct ModelCall: Sendable {
	let transport: any ModelTransport
	let diagnostics: DiagnosticsLog
	let watchdogSleep: @Sendable (Duration) async throws -> Void

	let authorizeInvocation: @Sendable (CompletionRequest) async throws -> Void

	func run(
		request: CompletionRequest,
		progress: @escaping AttemptProgressSink = { _ in }
	) async throws -> GenerateStep {
		try await authorizeInvocation(request)
		let watchdog = ChatWatchdog(sleep: watchdogSleep)
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

}

struct GenerateStep: Sendable {
	var text: String
	var toolCalls: [WireToolCall]
	var reason: FinishReason
	var usage: Usage

	func checkFinish() throws(AttemptFailure) {
		if reason == .error || reason == .contentFilter,
			text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		{
			throw AttemptFailure.generation(reason == .error ? .emptyAfterError : .contentFiltered)
		}
	}
}
