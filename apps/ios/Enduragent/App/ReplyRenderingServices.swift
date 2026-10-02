import EnduragentCoach

extension AppServices {
	var replyParser: ReplyParser {
		#if DEBUG
			if fixture?.replyParserFault == .fail { return .failingForProof }
		#endif
		return .foundation
	}
}
