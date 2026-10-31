import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension LiveCheckHelperTests {
	@Test func anUnknownChannelReadReportsWhatIntervalsAnsweredAndWhereTheCoachIsGivenTheName()
		async throws
	{
		var run = LiveReadsRun(
			folder: try LiveRunFolder(
				logs: try TestTemporaryFolders.make(), kind: .reads,
				startedAt: Date(timeIntervalSince1970: 899_164_800)),
			client: IntervalsRESTClient(credential: .apiKey("synthetic-intervals-key")),
			today: try #require(CivilDate(rawValue: "1998-06-13")))
		let name = "streams-unknown-channel"
		let probe = LiveReadsRun.unknownChannel
		let asked = try StreamChannels(requested: LiveReadsRun.probedChannels)
		let path = "/api/v1/activity/i5501/streams.json"
		let rejection = TappedResponse(
			method: "GET", path: path, query: "types=watts,velocity_smooth,\(probe)", status: 422,
			body: Data(
				#"{"status":422,"error":"Invalid stream type [enduragent_unknown_channel]"}"#.utf8))
		let samples = TappedResponse(
			method: "GET", path: path, query: "types=watts,velocity_smooth", status: 200,
			body: Data(
				#"[{"type":"watts","data":[200,210]},{"type":"velocity_smooth","data":[9.5,10.5]}]"#
					.utf8))
		let read = [
			StreamSamples(channel: "watts", values: [200, 210]),
			StreamSamples(channel: "velocity_smooth", values: [9.5, 10.5]),
		]

		LiveResponseTap.record(rejection)
		let refused = await run.read(name, audit: LiveReadAudit.streams) {
			throw IntervalsError(code: "http", details: "status 422", status: 422)
		}
		[rejection, samples].forEach(LiveResponseTap.record)
		let answered = await run.read(name, audit: LiveReadAudit.streams) {
			CoachReadout.streams(
				StreamSummary(summarizing: read, asked: asked, reported: [probe: .unknown]))
		}
		[rejection, samples].forEach(LiveResponseTap.record)
		let misfiled = await run.read(name, audit: LiveReadAudit.streams) {
			CoachReadout.streams(StreamSummary(summarizing: read, asked: asked, reported: [:]))
		}

		let refusal =
			#"HTTP 422 to GET /api/v1/activity/i5501/streams.json?types=watts,velocity_smooth,enduragent_unknown_channel: {"error":"Invalid stream type [enduragent_unknown_channel]","status":422}"#
		#expect(
			run.failures == [
				"\(name): the read threw http: status 422; intervals.icu answered \(refusal)"
			])
		#expect(LiveReadAudit.streamNames(name, asked: asked.names, outcome: answered).isEmpty)
		#expect(
			LiveReadAudit.streamNames(name, asked: asked.names, outcome: misfiled) == [
				"\(name): intervals.icu rejected enduragent_unknown_channel as an invalid stream type, but the coach is not given it under unknown"
			])
		#expect(
			LiveReadAudit.streamNames(
				"streams", asked: ["altitude"],
				outcome: LiveReadOutcome(responses: [], given: .object(["channels": .object([:])])))
				== [
					"streams: the coach is given altitude under no list instead of exactly one of unanswered, unknown or unread"
				])

		func parked(_ outcome: LiveReadOutcome) throws -> ParkedAnswer {
			try #require(
				LiveParkedQuestions.answers(
					LiveRawReads(
						streams: samples, unknownChannel: outcome, unknownChannelName: probe,
						askedChannels: asked.names)
				)
				.first { $0.question == "Stream types: comma-joined, and an unknown channel" })
		}
		func evidence(_ outcome: LiveReadOutcome) throws -> String? {
			try parked(outcome).evidence.first { $0.hasPrefix("unknown channel:") }
		}
		let joined = "matches: intervals.icu honours comma-joined types; "
		#expect(try evidence(refused) == "unknown channel: the app's read threw; \(refusal)")
		#expect(
			try parked(refused).verdict
				== joined + "mismatch: the app's read threw on the unknown channel \(probe)")
		#expect(
			try evidence(answered)
				== "unknown channel: the app's read answered; \(refusal); HTTP 200 to GET /api/v1/activity/i5501/streams.json?types=watts,velocity_smooth: enduragent_unknown_channel absent; channels returned: velocity_smooth, watts; the coach is given channels velocity_smooth, watts; unknown enduragent_unknown_channel"
		)
		#expect(
			try parked(answered).verdict
				== joined
				+ "matches: the read answered and the coach is given \(probe) under unknown")
		#expect(
			try parked(misfiled).verdict
				== joined
				+ "mismatch: the read answered but the coach is given \(probe) under unanswered")
	}
}
