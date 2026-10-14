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

	@Test func aFinishedCallWithNoUsageBlockIsChargedItsBound() async throws {
		let file = try TestTemporaryFolders.make().appending(path: "spend.tsv")
		let ledger = try LiveSpendLedger(file: file, limit: 10)
		let model = FakeModelTransport { _ in ScriptedReply([.text("ok"), .finish(reason: .stop)]) }
		let metered = LiveMeteredTransport(inner: model, ledger: ledger, log: LiveExchangeLog())
		let request = testRequest([WireMessage(role: .user, content: "/status", toolCalls: [])])

		_ = try await collect(metered.stream(request))

		let bound = LiveSpendEstimate.bound(for: request)
		#expect(abs(ledger.total - bound) < 1e-9)
		let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").dropFirst()
		#expect(
			rows.map { $0.split(separator: "\t").suffix(2).first.map(String.init) } == ["bound"])
	}

	@Test func theReadsCheckNamesWhatAnEmptyAccountLeavesUncovered() throws {
		#expect(
			LiveReadsRun.uncovered(LiveRawReads(activities: .array([]))) == [
				"not covered: the account has no activity in the last 30 days",
				"not covered: no activity detail or laps were read",
				"not covered: no ride's streams were read",
			])
		let streams = TappedResponse(
			method: "GET", path: "/api/v1/activity/i5501/streams", query: "types=watts",
			status: 200, body: Data("[]".utf8))
		#expect(
			LiveReadsRun.uncovered(
				LiveRawReads(
					activities: try JSONValue.parse(#"[{"id":"i5501"}]"#),
					details: [try JSONValue.parse(#"{"id":"i5501"}"#)], streams: streams)
			).isEmpty)
	}

	@Test func savedResponsesLoseTheirCredentialsAndASavedKeyFailsTheRun() throws {
		let key = "synthetic-intervals-key"
		var run = LiveReadsRun(
			folder: try LiveRunFolder(
				logs: try TestTemporaryFolders.make(), kind: .reads,
				startedAt: Date(timeIntervalSince1970: 899_164_800)),
			client: IntervalsRESTClient(credential: .apiKey(key)),
			today: try #require(CivilDate(rawValue: "1998-06-13")))
		let profile =
			#"{"id":"i1001","name":"Ada","icu_api_key":"synthetic-intervals-key","icu_friend_invite_token":"invite-0001","strava_password":null,"has_password":true,"sportSettings":[{"types":["Ride"],"ftp":250,"clientSecret":"secret-0001"}]}"#
		run.save(
			[
				TappedResponse(
					method: "GET", path: "/api/v1/athlete/0", query: nil, status: 200,
					body: Data(profile.utf8))
			], as: "profile")
		run.save(
			[
				TappedResponse(
					method: "GET", path: "/api/v1/athlete/0/wellness", query: nil, status: 401,
					body: Data("rejected synthetic-intervals-key".utf8))
			], as: "wellness-14-days")

		try run.writeFindings(checkingFor: key)

		let saved = try Data(contentsOf: run.folder.run.appending(path: "raw/1-profile.json"))
		#expect(
			try JSONValue.parse(String(decoding: saved, as: UTF8.self))
				== JSONValue.parse(
					#"{"id":"i1001","name":"Ada","icu_api_key":"","icu_friend_invite_token":"","strava_password":null,"has_password":true,"sportSettings":[{"types":["Ride"],"ftp":250,"clientSecret":""}]}"#
				))
		#expect(
			run.failures == [
				"raw/2-wellness-14-days.json: the saved file holds the intervals.icu key"
			])
	}

	@Test(arguments: [
		(JSONValue.null, "not supplied by this account"), (.string("1970-06-14"), "matches"),
		(.string("14/06/1970"), "mismatch"),
	])
	func aDateOfBirthTheAccountLeavesNullIsReportedAsNotSupplied(
		birth: JSONValue, verdict: String
	) {
		let answers = LiveParkedQuestions.answers(
			LiveRawReads(profile: .object(["icu_date_of_birth": birth])))

		#expect(
			answers.first { $0.question == "Format of icu_date_of_birth" }?.verdict == verdict)
	}
}
