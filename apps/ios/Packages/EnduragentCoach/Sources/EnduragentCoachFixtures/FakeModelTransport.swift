import EnduragentCoach
import Foundation

public final class FakeModelTransport: ModelTransport, @unchecked Sendable {
	public typealias Response = @Sendable (ScriptedRequest) -> ScriptedReply

	private let lock = NSLock()
	private let clock: any Clock
	private var response: Response
	private var history: [CompletionRequest] = []
	private var steps: [AttemptID: [ScriptedRequest.Purpose: Int]] = [:]
	package var finishUsage = Usage(inputTokens: 0, outputTokens: 0, cost: nil)

	public init(
		clock: any Clock = SystemClock(), respond: @escaping Response = { _ in ScriptedReply([]) }
	) {
		self.clock = clock
		self.response = respond
	}

	public var respond: Response {
		get { lock.withLock { response } }
		set { lock.withLock { response = newValue } }
	}

	package var requests: [CompletionRequest] {
		lock.withLock { history }
	}

	public var requestCount: Int {
		lock.withLock { history.count }
	}

	public var lastReplyLanguage: String? {
		lock.withLock {
			let system = history.last { $0.charge == .chatAttempt }?.messages.first?.content ?? ""
			guard let section = system.components(separatedBy: "# Reply language\n\n").last,
				section != system
			else { return nil }
			return section.split(separator: "\n", omittingEmptySubsequences: false).first
				.map(String.init)
		}
	}

	public var lastChatHistoryHead: String? {
		lock.withLock {
			let chat = history.last { $0.charge == .chatAttempt }
			return chat?.messages.dropFirst().first?.content
				.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
		}
	}

	package func stream(_ request: CompletionRequest) -> AsyncThrowingStream<TransportEvent, Error>
	{
		let (respond, scripted) = lock.withLock {
			history.append(request)
			let purpose = ScriptedRequest.Purpose(request.charge)
			let context =
				purpose == .chat
				? history.first {
					$0.attempt == request.attempt && $0.charge == .chatAttempt
				} ?? request : request
			let step = steps[request.attempt, default: [:]][purpose, default: 0]
			steps[request.attempt, default: [:]][purpose] = step + 1
			return (
				response,
				ScriptedRequest(request: request, context: context, purpose: purpose, step: step)
			)
		}
		let reply = respond(scripted)
		let gate = reply.gate
		let delay = reply.requestDelay
		let pause = reply.deltaDelay
		let usage = finishUsage
		let clock = clock
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					try await gate?.enter()
					if let delay { try await clock.sleep(for: delay) }
					for event in reply.events {
						if let pause { try await clock.sleep(for: pause) }
						switch event {
						case .text(let text):
							continuation.yield(.textDelta(text))
						case .toolCall(let name, let arguments):
							continuation.yield(
								.toolCall(
									WireToolCall(
										id: UUID().uuidString, name: name, arguments: arguments)))
						case .finish(let reason):
							continuation.yield(.finished(reason: reason, usage: usage))
							continuation.finish()
							return
						case .fail(let failure):
							throw failure.failure
						case .keepWorking:
							while !Task.isCancelled {
								try await Task.sleep(for: .seconds(10))
								continuation.yield(.heartbeat)
							}
							continuation.finish()
							return
						case .hang:
							while !Task.isCancelled { try await Task.sleep(for: .seconds(60)) }
							continuation.finish()
							return
						}
					}
					continuation.finish()
				} catch is CancellationError {
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}
