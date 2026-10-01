public enum FinishReason: String, Sendable {
	case stop
	case toolCalls = "tool-calls"
	case length
	case contentFilter = "content_filter"
	case error
}
