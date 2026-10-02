#if DEBUG
	import EnduragentCoach
	import Foundation

	extension ReplyParser {
		public static let failing = Self { _ in throw NSError(domain: "ReplyParserFixture", code: 1)
		}
	}
#endif
