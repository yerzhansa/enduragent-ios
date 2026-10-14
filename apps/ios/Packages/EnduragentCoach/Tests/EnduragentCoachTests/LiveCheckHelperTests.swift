import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LiveCheckHelperTests {
	@Test func anAbsentKeyStopsWithOneLineNamingItsServiceAndHowToAddIt() throws {
		let lookUp: (LiveKey) -> KeychainLookup = { key in
			key == .intervals
				? KeychainLookup(status: KeychainLookup.itemNotFound, output: Data())
				: KeychainLookup(status: 0, output: Data("synthetic-model-key\n".utf8))
		}

		let stop = #expect(throws: LiveCheckStop.self) {
			try LiveKey.secrets(LiveKey.allCases, lookUp: lookUp)
		}

		#expect(
			stop?.description
				== "Missing Keychain item enduragent-m3-intervals-api-key. Add it with: security add-generic-password -a \"$USER\" -s enduragent-m3-intervals-api-key -w"
		)
		#expect(stop?.description.contains("synthetic-model-key") == false)
	}

	@Test func anEmptyOrUnreadableKeyStopsAndAPresentKeyLosesOnlyItsLineBreak() throws {
		let empty = #expect(throws: LiveCheckStop.self) {
			try LiveKey.openRouter.secret(from: KeychainLookup(status: 0, output: Data("\n".utf8)))
		}
		#expect(empty?.description == LiveKey.openRouter.missingLine)
		let failed = #expect(throws: LiveCheckStop.self) {
			try LiveKey.openRouter.secret(from: KeychainLookup(status: 51, output: Data()))
		}
		#expect(failed?.description.contains("status 51") == true)
		let found = try LiveKey.secrets(LiveKey.allCases) { _ in
			KeychainLookup(status: 0, output: Data("synthetic key\n".utf8))
		}
		#expect(found == [.intervals: "synthetic key", .openRouter: "synthetic key"])
	}

	@Test func theLedgerRefusesACallThatWouldPassTheLimitAndKeepsItsTotalAcrossRuns() throws {
		let file = try TestTemporaryFolders.make().appending(path: "spend.tsv")
		let ledger = try LiveSpendLedger(file: file, limit: 10)
		ledger.label("status#1")
		try ledger.charge(
			model: testModel, usage: Usage(inputTokens: 900, outputTokens: 80, cost: 9.6), bound: 1,
			at: Date(timeIntervalSince1970: 899_164_800))

		#expect(throws: Never.self) { try ledger.admit(0.4) }
		#expect(!ledger.capReached)
		#expect(throws: ProviderFailure.accessExhausted) { try ledger.admit(0.41) }
		#expect(ledger.capReached)
		#expect(throws: ProviderFailure.accessExhausted) { try ledger.admit(0) }
		let reopened = try LiveSpendLedger(file: file, limit: 10)
		#expect(abs(reopened.total - 9.6) < 1e-9)
		let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
		#expect(rows.first.map(String.init) == LiveSpendLedger.header)
		#expect(
			rows.dropFirst().map { $0.split(separator: "\t").dropFirst().map(String.init) } == [
				[
					"status#1", testModel.rawValue, "900", "80", "9.600000", "reported", "9.600000",
				]
			])
	}

	@Test func aCallWithoutAReportedCostIsChargedByTokensOrByItsBound() throws {
		let file = try TestTemporaryFolders.make().appending(path: "spend.tsv")
		let ledger = try LiveSpendLedger(file: file, limit: 10)

		try ledger.charge(
			model: testModel, usage: Usage(inputTokens: 1_000, outputTokens: 100, cost: nil),
			bound: 1, at: Date(timeIntervalSince1970: 899_164_800))
		try ledger.charge(
			model: testModel, usage: nil, bound: 0.42, at: Date(timeIntervalSince1970: 899_164_800))

		let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").dropFirst()
		#expect(
			rows.map { $0.split(separator: "\t").suffix(3).map(String.init) } == [
				["0.007500", "tokens", "0.007500"], ["0.420000", "bound", "0.427500"],
			])
	}

	@Test func theMeteredTransportNeverReachesTheModelPastTheCapAndChargesWhatItReports()
		async throws
	{
		let file = try TestTemporaryFolders.make().appending(path: "spend.tsv")
		let ledger = try LiveSpendLedger(file: file, limit: 10)
		let model = FakeModelTransport { _ in ScriptedReply([.text("ok"), .finish(reason: .stop)]) }
		model.finishUsage = Usage(inputTokens: 12, outputTokens: 3, cost: 0.25)
		let log = LiveExchangeLog()
		let metered = LiveMeteredTransport(inner: model, ledger: ledger, log: log)
		let request = testRequest([WireMessage(role: .user, content: "/status", toolCalls: [])])

		_ = try await collect(metered.stream(request))
		#expect(abs(ledger.total - 0.25) < 1e-9)
		#expect(log.drain().map(\.usage) == [Usage(inputTokens: 12, outputTokens: 3, cost: 0.25)])

		try ledger.charge(
			model: testModel, usage: Usage(inputTokens: 0, outputTokens: 0, cost: 9.6),
			bound: 0, at: Date(timeIntervalSince1970: 899_164_800))
		await #expect(throws: ProviderFailure.accessExhausted) {
			_ = try await collect(metered.stream(request))
		}
		#expect(model.requestCount == 1)
		#expect(LiveSpendEstimate.bound(for: request) > 0.4)
	}

	@Test func theAuditNamesEveryValueTheResponseHasButTheCoachIsNotGiven() throws {
		let wellness = try JSONValue.parse(
			#"[{"id":"1998-06-12","ctl":40,"atl":45,"hrv":61,"fatigue":null},{"id":"1998-06-13","ctl":41}]"#
		)
		let shown = try JSONValue.parse(
			#"{"days":[{"date":"1998-06-12","fitness":40,"fatigue":45},{"date":"1998-06-13","fitness":41}]}"#
		)
		#expect(
			LiveReadAudit.wellness(raw: wellness, given: shown) == [
				"wellness 1998-06-12: the response has hrv but the coach is given no hrv"
			])

		let athlete = try JSONValue.parse(
			#"{"id":"i1001","icu_weight":null,"weight":71,"sportSettings":[{"types":["Run"],"ftp":300},{"types":["Ride"],"ftp":250,"lthr":168}]}"#
		)
		#expect(
			Set(LiveReadAudit.profile(raw: athlete, given: try JSONValue.parse(#"{"ftp":250}"#)))
				== [
					"profile: the response has cycling settings lthr but the coach is given no lthr",
					"profile: the response has athlete weight but the coach is given no weight",
					"profile: the response has cycling settings types but the coach is given no sports",
				])

		let detail = try JSONValue.parse(
			#"{"id":"i5501","type":"Ride","start_date_local":"1998-06-12T08:00:00","icu_rpe":6,"icu_intervals":[{"type":"WORK","average_watts":250},{"type":"RECOVERY"}]}"#
		)
		let given = try JSONValue.parse(
			#"{"activity":{"id":"i5501","sport":"Ride","start":"1998-06-12T08:00:00","rpe":6},"laps":[{"number":1,"kind":"WORK"},{"number":2,"kind":"RECOVERY"}]}"#
		)
		#expect(
			LiveReadAudit.activity(raw: detail, given: given) == [
				"activity i5501 lap 1: the response has average_watts but the coach is given no averagePower"
			])
	}

	@Test func theAuditCountsStravaHiddenRowsAndAcceptsTheirDetailAnswer() throws {
		let hidden =
			#"{"id":"i5502","start_date_local":"1998-06-12T09:00:00","source":"STRAVA","_note":"hidden"}"#
		let listed = try JSONValue.parse("[\(hidden)]")
		#expect(
			LiveReadAudit.activities(
				raw: listed, given: try JSONValue.parse(#"{"activities":[],"hiddenByStrava":0}"#))
				== ["activities: 1 rows are hidden by Strava but the coach is told 0"])
		#expect(
			LiveReadAudit.activities(
				raw: listed, given: try JSONValue.parse(#"{"activities":[],"hiddenByStrava":1}"#)
			)
			.isEmpty)
		#expect(
			LiveReadAudit.activity(
				raw: try JSONValue.parse(hidden),
				given: try JSONValue.parse(#"{"error":"activity_hidden_by_strava"}"#)
			).isEmpty)
	}

	@Test func theSnapshotCheckFlagsOnlyNumbersOutsideTheSpecBands() {
		let section = """
			# Athlete Profile & Latest Wellness

			Profile: FTP 720 W (not usable) · LTHR 168 bpm · resting HR 25 bpm · weight 71 kg
			Wellness 1998-06-13: Fitness 41 · Fatigue 45 · Form -4 · weight 210.5 kg
			"""

		#expect(
			LiveReadAudit.snapshotOutOfRange(section) == [
				"snapshot: resting HR 25 bpm is outside 30.0...220.0",
				"snapshot: weight 210.5 kg is outside 30.0...200.0",
			])
		#expect(LiveReadAudit.snapshotOutOfRange("Profile: FTP 601 W").count == 1)
	}

	@Test func theVerdictNamesMissedToolCallsCalendarCallsAndAUTCStart() throws {
		let message = "/review deep the ride"
		let request = testRequest([
			WireMessage(role: .system, content: "rules", toolCalls: []),
			WireMessage(role: .user, content: message + "\nCurrent time: 08:00", toolCalls: []),
		])
		func turn(_ calls: [(String, String)], reply: String) -> LiveTurnRecord {
			LiveTurnRecord(
				message: message,
				exchanges: [
					LiveExchange(
						request: request,
						events: calls.enumerated().map { index, call in
							.toolCall(
								WireToolCall(id: "call-\(index)", name: call.0, arguments: call.1))
						}, failure: nil)
				], reply: reply, outcome: "completed", reviewPending: false, calendarWrites: 0)
		}
		let expectations: [LiveExpectation] = [
			.callsWith(.intervalsFetchStreams, argument: "activityId", oneOf: [.string("i5501")]),
			.replyMentions(["Fitness"]),
		]

		let good = turn(
			[("intervals_fetch_streams", #"{"activityId":"i5501"}"#)],
			reply: "Fitness held; the ride started at 08:00 local time.")
		#expect(LiveVerdict.violations(of: good, against: expectations).isEmpty)

		let bad = turn(
			[("intervals_create_workout", "{}"), ("intervals_fetch_streams", "not json")],
			reply: "The ride started at 08:00 UTC.")
		#expect(
			LiveVerdict.violations(of: bad, against: expectations) == [
				"the reply labels a time UTC",
				"calendar tools were called: intervals_create_workout",
				"intervals_fetch_streams was called with arguments that are not JSON",
				#"intervals_fetch_streams was not called with activityId "i5501""#,
				"the reply does not mention Fitness",
			])
	}
}
