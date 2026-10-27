import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ScrubTests {
	static let npmTable: [(String, String)] = [
		("see https://example.com/a?b=1 now", "see [redacted] now"),
		("HTTPS://EXAMPLE.COM/A", "[redacted]"),
		("open ftp+x.y-z://host/file", "open [redacted]"),
		(#"say "http://a.example/c" then"#, #"say "[redacted]" then"#),
		("<http://a.example/c>", "<[redacted]>"),
		("Authorization: Bearer abc.def-ghi", "Authorization: [redacted]"),
		("basic dXNlcjpwYXNz, next", "[redacted], next"),
		("BEARER token;rest", "[redacted];rest"),
		("key sk-or-v1-abc end", "key [redacted] end"),
		("SK-ABC_def-1", "[redacted]"),
		("task-force mask-up", "task-force mask-up"),
		("My knee hurts after 3 x 20 min at 250 W.", "My knee hurts after 3 x 20 min at 250 W."),
		("Bearer https://example.com/a;b", "[redacted]"),
		("sk-abc://host/x", "[redacted]"),
	]

	@Test(arguments: npmTable)
	func npmRedactionTableInNpmOrder(_ raw: String, _ expected: String) {
		#expect(Scrub.clean(raw) == expected)
	}

	@Test(arguments: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"])
	func githubTokensAreRedacted(_ prefix: String) {
		let token = prefix + String(repeating: "a1B_", count: 10)
		#expect(Scrub.clean("token \(token) end") == "token [redacted] end")
	}

	@Test func nulIsRemovedBeforeThePatternsRun() {
		#expect(Scrub.clean("a\u{0}b") == "ab")
		#expect(Scrub.clean("s\u{0}k-abc") == "[redacted]")
	}

	@Test func textIsCutToTheLimitInUTF16Units() {
		#expect(Scrub.limit == 2_000)
		#expect(
			Scrub.clean(String(repeating: "a", count: 2_100))
				== String(repeating: "a", count: 2_000))
		let emojiAcrossTheEdge = String(repeating: "a", count: 1_999) + "😀b"
		#expect(Scrub.clean(emojiAcrossTheEdge) == String(repeating: "a", count: 1_999))
	}

	@Test func aTokenAcrossTheLimitIsRedactedBeforeTheCut() {
		let cleaned = Scrub.clean(String(repeating: "a", count: 1_995) + " sk-abcdefgh")
		#expect(cleaned.utf16.count == 2_000)
		#expect(!cleaned.contains("sk-"))
	}

	@Test(arguments: npmTable.map(\.0) + ["Bearer x", String(repeating: "b ", count: 1_200)])
	func scrubbingTwiceChangesNothing(_ raw: String) {
		let once = Scrub.clean(raw)
		#expect(Scrub.clean(once) == once)
	}
}
