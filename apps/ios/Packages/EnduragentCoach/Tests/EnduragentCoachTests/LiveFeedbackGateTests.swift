import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LiveFeedbackGateTests {
	static let selected = ["ENDURAGENT_LIVE": "feedback"]

	let logs: URL

	init() throws {
		logs = try TestTemporaryFolders.make()
	}

	@Test func refusesWithoutTheSelector() {
		#expect(
			LiveFeedbackRun.refusal(environment: ["ENDURAGENT_LIVE": ""], log: nil) == .notSelected)
		#expect(LiveFeedbackRun.refusal(environment: [:], log: nil) == .notSelected)
	}

	@Test func refusesWhenTheLogHoldsARow() {
		#expect(
			LiveFeedbackRun.refusal(environment: Self.selected, log: Self.log(rows: 1))
				== .alreadyPosted)
	}

	@Test func allowsOnlyFeedbackAndAnEmptyLog() {
		#expect(LiveFeedbackRun.refusal(environment: Self.selected, log: nil) == nil)
		#expect(LiveFeedbackRun.refusal(environment: Self.selected, log: Self.log(rows: 0)) == nil)
		#expect(
			LiveFeedbackRun.refusal(environment: ["ENDURAGENT_LIVE": "coach"], log: nil)
				== .notSelected)
	}

	@Test func aRefusedRunMakesNoRequest() async throws {
		let server = FakeFeedbackServer()
		let log = logs.appending(path: "feedback-note.tsv")
		try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
		try Self.log(rows: 1).write(to: log)
		let refusal = try await LiveFeedbackRun.run(
			using: server.client, environment: Self.selected, log: log,
			directory: try TestTemporaryFolders.make())
		#expect(refusal == .alreadyPosted)
		#expect(server.requestCount == 0)
		#expect(try Data(contentsOf: log) == Self.log(rows: 1))
	}

	@Test func anAllowedRunPostsOneNoteAndAppendsItsRow() async throws {
		let server = FakeFeedbackServer()
		let log = logs.appending(path: "LIVE/feedback-note.tsv")
		let refusal = try await LiveFeedbackRun.run(
			using: server.client, environment: Self.selected, log: log,
			directory: try TestTemporaryFolders.make())
		#expect(refusal == nil)
		#expect(server.requestCount == 1)
		#expect(server.storedCount == 1)
		let note = try #require(try server.requests.first?.note())
		#expect(note.text == LiveFeedbackRun.note)
		let lines = String(decoding: try Data(contentsOf: log), as: UTF8.self)
			.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
		#expect(lines.first == ["time", "id", "answers", "outcome"])
		#expect(
			lines.dropFirst().map { Array($0.dropFirst()) } == [[note.id, "stored", "received"]])
		let again = try await LiveFeedbackRun.run(
			using: server.client, environment: Self.selected, log: log,
			directory: try TestTemporaryFolders.make())
		#expect(again == .alreadyPosted)
		#expect(server.requestCount == 1)
	}

	private static func log(rows: Int) -> Data {
		let row = "2026-10-28T08:00:00Z\tnote\tstored\treceived\n"
		return Data((LiveFeedbackRun.header + "\n" + String(repeating: row, count: rows)).utf8)
	}
}
