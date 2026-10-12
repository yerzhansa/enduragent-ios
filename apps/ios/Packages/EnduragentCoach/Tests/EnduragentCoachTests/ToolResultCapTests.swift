import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ToolResultCapTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)

	@Test func oversizedArrayReportsEveryOmittedRow() async throws {
		try await expectOmitted(.array(oversizedRows(150)), records: 150)
	}

	@Test func oversizedObjectCountsOnlyItsLargestDirectArray() async throws {
		try await expectOmitted(
			.object([
				"rows": .array(oversizedRows(150)),
				"otherRows": .array(oversizedRows(10)),
				"nested": .object(["rows": .array(oversizedRows(200))]),
				"reportedCount": .number(999),
			]), records: 150)
	}

	@Test func oversizedObjectWithOnlyDeeperRowsReportsZero() async throws {
		try await expectOmitted(
			.object(["nested": .object(["rows": .array(oversizedRows(150))])]), records: 0)
	}

	@Test func oversizedScalarReportsZero() async throws {
		try await expectOmitted(
			.string(String(repeating: "omitted-row", count: 10_000)), records: 0)
	}

	@Test(arguments: [100, 23_999, 24_000])
	func resultsAtOrBelowCapStayIntact(tokens: Int) async throws {
		let payload = payload(estimatedTokens: tokens)
		#expect(estimateTokens(UntrustedEnvelope.wrap(payload).canonicalDigestInput()) == tokens)
		let result = try await toolResult(payload)
		#expect(result.objectFields["data"] == payload)
		#expect(result.objectFields["untrusted_data"] == .string(UntrustedEnvelope.banner))
		#expect(result.objectFields["truncated"] == nil)
	}

	@Test func resultJustAboveCapIsOmitted() async throws {
		let payload = payload(estimatedTokens: 24_001)
		#expect(estimateTokens(UntrustedEnvelope.wrap(payload).canonicalDigestInput()) == 24_001)
		try await expectOmitted(payload, records: 1)
	}

	private func oversizedRows(_ count: Int) -> [JSONValue] {
		(0..<count).map { index in
			.object([
				"label": .string("omitted-row-\(index)"),
				"details": .string(String(repeating: "x", count: 1024)),
			])
		}
	}

	private func payload(estimatedTokens: Int) -> JSONValue {
		let empty: JSONValue = .object(["rows": .array([.string("")])])
		let overhead = UntrustedEnvelope.wrap(empty).canonicalDigestInput().utf16.count
		let characters = estimatedTokens * 10 / 3 - overhead
		return .object(["rows": .array([.string(String(repeating: "x", count: characters))])])
	}

	private func expectOmitted(_ payload: JSONValue, records: Int) async throws {
		let result = try await toolResult(payload)
		let fields = result.objectFields
		#expect(fields["truncated"] == .bool(true))
		#expect(fields["omittedSamples"] == .number(Double(records)))
		let estimated = estimateTokens(UntrustedEnvelope.wrap(payload).canonicalDigestInput())
		#expect(estimated > 24_000)
		#expect(fields["estimatedTokens"] == .number(Double(estimated)))
		let notice = try #require(fields["notice"]?.stringValue)
		#expect(notice.contains("~\(estimated) tokens"))
		#expect(notice.contains("Rerun with narrower arguments"))
		#expect(notice.contains("a smaller date range, fewer stream types, or a shorter activity"))
		#expect(Set(fields.keys) == ["truncated", "notice", "omittedSamples", "estimatedTokens"])
		#expect(!result.canonicalDigestInput().contains("omitted-row"))
	}

	private func toolResult(_ payload: JSONValue) async throws -> JSONValue {
		intervals.streams = payload
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_fetch_streams", arguments: #"{"activityId":"i1234567"}"#),
				.finish(reason: .toolCalls),
				.text("Read complete."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: InMemoryRecordLog())
		let settled = try await coach.sendAndSettle("Read my training data")
		#expect(replyText(settled) == "Read complete.")
		try #require(transport.requests.count == 2)
		let next = try #require(transport.requests.last)
		let call = try #require(next.messages.flatMap(\.toolCalls).first)
		let result = try #require(next.messages.last { $0.role == .tool })
		#expect(call.name == "intervals_fetch_streams")
		#expect(result.toolCallId == call.id)
		return try JSONValue.parse(result.content)
	}
}
