import EnduragentCoach

public enum PartialFlushFixture {
	public static let writes: [ScriptedEvent] = [
		.toolCall(
			name: ToolName.memoryWrite.rawValue,
			arguments:
				#"{"section":"schedule","content":"Rides with a group on Saturdays."}"#),
		.toolCall(
			name: ToolName.ledgerAppend.rawValue,
			arguments:
				#"{"kind":"decision","date":"1998-06-15","text":"Keeps Saturdays for the group ride."}"#
		),
		.finish(reason: .toolCalls),
	]

	public static func responses(failingWith failure: ScriptedFailure = .http(status: 500))
		-> FakeModelTransport.Response
	{
		ScriptedReply.sequence(writes, for: .flush, repeatingFailure: failure)
	}
}
