#if os(macOS)
	import EnduragentCoachFixtures
	import Foundation
	import Testing

	@testable import EnduragentCoach

	@Suite(.serialized) struct LiveFeedbackNote {
		@Test(.enabled(if: LiveCheck.selected == .feedback), .timeLimit(.minutes(1)))
		func postsTheOneAllowedNote() async throws {
			let environment = ProcessInfo.processInfo.environment
			guard let logs = environment[LiveCheck.logsVariable], !logs.isEmpty else {
				Issue.record(
					"\(LiveCheck.logsVariable) is not set. Run the check through make live-feedback-note."
				)
				return
			}
			let log = URL(fileURLWithPath: logs, isDirectory: true).appending(
				path: "feedback-note.tsv")
			let gate = LiveFeedbackRun.refusal(
				environment: environment, log: try LiveFeedbackRun.existingLog(at: log))
			guard gate == nil else {
				Issue.record("The live feedback note is refused: \(String(describing: gate)).")
				return
			}
			let refusal = try await LiveFeedbackRun.run(
				using: FeedbackClient.live, environment: environment, log: log,
				directory: try TestTemporaryFolders.make())
			#expect(refusal == nil)
			let row = try #require(
				String(decoding: try Data(contentsOf: log), as: UTF8.self)
					.split(separator: "\n").last)
			#expect(row.hasSuffix("\treceived"), "\(row)")
		}
	}
#endif
