import EnduragentCoach
import Foundation
import Synchronization

public struct ScriptedReply: Sendable {
	package let events: [ScriptedEvent]
	package let requestDelay: Duration?
	package let deltaDelay: Duration?

	public init(
		_ events: [ScriptedEvent], requestDelay: Duration? = nil, deltaDelay: Duration? = nil
	) {
		self.events = events
		self.requestDelay = requestDelay
		self.deltaDelay = deltaDelay
	}

	public func step(_ index: Int, repeatingHang: Bool = false) -> ScriptedReply {
		var remaining = events
		for _ in 0..<index {
			_ = Self.takeStep(from: &remaining, repeatingHang: repeatingHang)
		}
		return ScriptedReply(
			Self.takeStep(from: &remaining, repeatingHang: repeatingHang),
			requestDelay: requestDelay, deltaDelay: deltaDelay)
	}

	public static func sequence(
		_ events: [ScriptedEvent], for purpose: ScriptedRequest.Purpose = .chat,
		repeatingFailure: ScriptedFailure? = nil,
		requestDelay: Duration? = nil, deltaDelay: Duration? = nil,
		otherwise fallback: @escaping FakeModelTransport.Response = { _ in ScriptedReply([]) }
	) -> FakeModelTransport.Response {
		let remaining = Mutex(events)
		return { request in
			guard request.purpose == purpose else { return fallback(request) }
			return remaining.withLock {
				var step = takeStep(from: &$0, repeatingHang: false)
				if step.isEmpty, let repeatingFailure {
					step = [.fail(repeatingFailure)]
				}
				return ScriptedReply(
					step,
					requestDelay: requestDelay, deltaDelay: deltaDelay)
			}
		}
	}

	private static func takeStep(from events: inout [ScriptedEvent], repeatingHang: Bool)
		-> [ScriptedEvent]
	{
		var step: [ScriptedEvent] = []
		while let event = events.first {
			step.append(event)
			if event != .hang || !repeatingHang { events.removeFirst() }
			switch event {
			case .text, .toolCall: continue
			case .finish, .fail, .hang: return step
			}
		}
		return step
	}
}
