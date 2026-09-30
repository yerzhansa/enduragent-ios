import Foundation

public struct ScriptedReply: Sendable {
	package var events: [ScriptedEvent]
	package let requestDelay: Duration?
	package let deltaDelay: Duration?
	package let flush: [ScriptedEvent]?
	package let flushDelay: Duration?

	public init(
		_ events: [ScriptedEvent], requestDelay: Duration? = nil,
		deltaDelay: Duration? = nil, flush: [ScriptedEvent]? = nil, flushDelay: Duration? = nil
	) {
		self.events = events
		self.requestDelay = requestDelay
		self.deltaDelay = deltaDelay
		self.flush = flush
		self.flushDelay = flushDelay
	}
}
