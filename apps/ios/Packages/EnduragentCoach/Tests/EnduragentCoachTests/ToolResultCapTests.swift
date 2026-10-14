import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ToolResultCapTests {
	let transport = FakeModelTransport()
	static let ride = Activity.recorded("i1234567", "Sunday long ride", on: "1998-06-07")
	static let detailTool = "intervals_fetch_activity"
	static let detailArguments = #"{"activityId":"i1234567"}"#
	static let noNarrowing =
		"No argument of this tool narrows its result, so calling it again gives the same answer."

	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()

	@Test func oversizedArrayReportsEveryOmittedRow() async throws {
		intervals.events = (1...150).map { number in
			CalendarEvent(
				id: EventID(rawValue: number), startDateLocal: "1998-06-14T00:00:00",
				name: wide(number), category: "WORKOUT", externalId: nil, uid: nil, tags: [],
				coachCreated: false)
		}
		try await expectOmitted(
			"intervals_list_events", #"{"oldest":"1998-06-14","newest":"1998-06-14"}"#,
			records: 150, advice: "Rerun with a smaller date range.")
	}

	@Test func oversizedObjectCountsItsLargestDirectArray() async throws {
		intervals.athlete = AthleteProfile.cyclist(name: "Ada", ftp: 250).with(
			[:], settingsSports: (0..<10).map(wide),
			powerZones: (0..<150).map { TrainingZone(name: wide($0), upperBound: Double($0)) },
			heartRateZones: (0..<20).map { TrainingZone(name: wide($0), upperBound: Double($0)) })
		try await expectOmitted(
			"intervals_fetch_athlete", "{}", records: 150, advice: Self.noNarrowing)
	}

	@Test func oversizedObjectDoesNotCountADeeperArray() async throws {
		try seed(
			detail(
				zones: 200,
				laps: .recorded(
					(1...150).map {
						ActivityLap(number: $0, label: wide($0), kind: nil, readings: Readings([:]))
					})))
		try await expectOmitted(
			Self.detailTool, Self.detailArguments, records: 150, advice: Self.noNarrowing)
	}

	@Test func oversizedObjectWithOnlyDeeperRowsReportsZero() async throws {
		try seed(detail(zones: 150, laps: .notSupplied))
		try await expectOmitted(
			Self.detailTool, Self.detailArguments, records: 0, advice: Self.noNarrowing)
	}

	@Test func oversizedTextReportsZero() async throws {
		let hidden = SectionName.cyclingEffective.filter { !$0.inject }
		try await EnduragentCoachTests.seed(
			store,
			hidden.enumerated().map { index, section in
				storedRecord(
					device: store.deviceId, wall: Int64(index + 1), ulid: fixedUlid(index + 1),
					account: testConnection.account,
					body: .synced(
						.memorySection(
							MemorySectionBody(
								name: section,
								content: (0..<40).map(wide).joined(separator: "\n")))))
			})
		try await expectOmitted(
			"memory_read", "{}", records: 0, advice: Self.noNarrowing)
	}

	@Test(arguments: [100, 23_999, 24_000])
	func resultsAtOrBelowCapStayIntact(tokens: Int) async throws {
		let payload = try seedDetail(estimatedTokens: tokens)
		#expect(estimateTokens(UntrustedEnvelope.wrap(payload).canonicalDigestInput()) == tokens)
		let result = try await toolResult(Self.detailTool, Self.detailArguments)
		#expect(result.objectFields["data"] == payload)
		#expect(result.objectFields["untrusted_data"] == .string(UntrustedEnvelope.banner))
		#expect(result.objectFields["truncated"] == nil)
	}

	@Test func resultJustAboveCapIsOmitted() async throws {
		let payload = try seedDetail(estimatedTokens: 24_001)
		#expect(estimateTokens(UntrustedEnvelope.wrap(payload).canonicalDigestInput()) == 24_001)
		let fields = try await expectOmitted(
			Self.detailTool, Self.detailArguments, records: 1, advice: Self.noNarrowing)
		#expect(fields["estimatedTokens"] == .number(24_001))
	}

	private func wide(_ index: Int) -> String {
		"omitted-row-\(index)" + String(repeating: "x", count: 1024)
	}

	private func detail(notes: String? = nil, zones: Int = 0, laps: Laps) throws
		-> ActivityDetailRead
	{
		.found(
			try ActivityDetail(
				asked: Self.ride.id, activity: Self.ride,
				extras: ActivityDetailExtras(
					notes: notes,
					powerZoneSeconds: (0..<zones).map { ZoneSeconds(zone: wide($0), seconds: 60) }),
				laps: laps))
	}

	private func seed(_ read: ActivityDetailRead) {
		intervals.activities = [Self.ride]
		intervals.details[Self.ride.id] = read
	}

	private func seedDetail(estimatedTokens: Int) throws -> JSONValue {
		let lap = Laps.recorded([
			ActivityLap(number: 1, label: nil, kind: nil, readings: Readings([:]))
		])
		let empty = CoachReadout.activity(try detail(notes: "", laps: lap), asked: Self.ride.id)
		let overhead = UntrustedEnvelope.wrap(empty).canonicalDigestInput().utf16.count
		let read = try detail(
			notes: String(repeating: "x", count: estimatedTokens * 10 / 3 - overhead), laps: lap)
		seed(read)
		return CoachReadout.activity(read, asked: Self.ride.id)
	}

	@discardableResult
	private func expectOmitted(
		_ tool: String, _ arguments: String, records: Int, advice: String
	) async throws -> [String: JSONValue] {
		let result = try await toolResult(tool, arguments)
		let fields = result.objectFields
		#expect(fields["truncated"] == .bool(true))
		#expect(fields["omittedSamples"] == .number(Double(records)))
		let estimated = try #require(fields["estimatedTokens"]?.intValue())
		#expect(estimated > 24_000)
		let notice = try #require(fields["notice"]?.stringValue)
		#expect(
			notice
				== "Tool result too large (~\(estimated) tokens) and was omitted to protect context. "
				+ advice)
		#expect(Set(fields.keys) == ["truncated", "notice", "omittedSamples", "estimatedTokens"])
		#expect(!result.canonicalDigestInput().contains("omitted-row"))
		return fields
	}

	private func toolResult(_ tool: String, _ arguments: String) async throws -> JSONValue {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: tool, arguments: arguments),
				.finish(reason: .toolCalls),
				.text("Read complete."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store)
		let settled = try await coach.sendAndSettle("Read my training data")
		#expect(replyText(settled) == "Read complete.")
		try #require(transport.requests.count == 2)
		let next = try #require(transport.requests.last)
		let call = try #require(next.messages.flatMap(\.toolCalls).first)
		let result = try #require(next.messages.last { $0.role == .tool })
		#expect(call.name == tool)
		#expect(result.toolCallId == call.id)
		return try JSONValue.parse(result.content)
	}
}
