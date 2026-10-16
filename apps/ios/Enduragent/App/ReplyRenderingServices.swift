import EnduragentCoach

extension AppServices {
	var replyParser: ReplyParser {
		#if DEBUG
			if let fixture { return fixture.replyParser }
		#endif
		return .foundation
	}
}
