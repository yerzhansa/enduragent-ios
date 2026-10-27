import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PlanningToolTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let almaty = FixedClock(now: "1998-06-13T20:30:00Z", timeZone: "Asia/Almaty")
	let profile =
		#"{"experienceLevel":"intermediate","ftpWatts":250,"volumeTier":"medium","scheduleType":"flexible","goalType":"race","raceType":"gran_fondo","raceDate":"1998-08-09"}"#

	@Test func theDraftCountsWeeksFromThePhonesDay() async throws {
		let draft = try await draftFromATurn(clock: almaty, store: store)

		let id = try #require(draft.objectFields["id"]?.stringValue)
		let ulid = try #require(ULID(rawValue: id))
		#expect(ulid.time == almaty.now)
		#expect(draft.objectFields["createdAt"] == .string("1998-06-13T20:30:00.000Z"))
		#expect(draft.objectFields["totalWeeks"] == .number(8))
		#expect(
			draft
				== (try Planning.draft(
					try PlanningArguments.profile(try JSONValue.parse(profile)),
					today: "1998-06-14",
					options: PlanDraftOptions(
						id: id, createdAt: "1998-06-13T20:30:00.000Z", totalWeeks: nil)
				).json))
	}

	@Test func aDraftIsEnvelopedLikeEveryReadAndWritesNothingElse() async throws {
		let control = InMemoryRecordLog()
		let replied = FakeModelTransport()
		replied.respond = ScriptedReply.sequence(
			[.text("Here is your plan."), .finish(reason: .stop)], otherwise: replied.respond)
		let plain = await makeCoach(
			transport: replied, intervals: FakeIntervalsClient(athleteName: "Ada", ftp: 250),
			store: control, clock: almaty)
		let plainTurn = try await plain.sendAndSettle("Build me a plan")
		#expect(replyText(plainTurn) == "Here is your plan.")

		let draft = try await draftFromATurn(clock: almaty, store: store)

		#expect(draft.objectFields["status"] == .string("draft"))
		#expect(draft.objectFields["phases"]?.arrayValue?.isEmpty == false)
		#expect(try await recordKinds(in: store) == (try await recordKinds(in: control)))
		#expect(!intervals.calls.contains { $0.isCalendarCall })
	}

	private func draftFromATurn(clock: FixedClock, store: InMemoryRecordLog) async throws
		-> JSONValue
	{
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: "build_plan_skeleton", arguments: profile),
				.finish(reason: .toolCalls), .text("Here is your plan."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)

		let settled = try await coach.sendAndSettle("Build me a plan")

		#expect(replyText(settled) == "Here is your plan.")
		let next = try #require(transport.requests.last)
		let result = try #require(next.messages.last { $0.role == .tool })
		let envelope = try JSONValue.parse(result.content)
		#expect(envelope.objectFields.keys.sorted() == ["data", "untrusted_data"])
		#expect(envelope.objectFields["untrusted_data"] == .string(UntrustedEnvelope.banner))
		return try #require(envelope.objectFields["data"])
	}

	private func recordKinds(in store: InMemoryRecordLog) async throws -> [String] {
		let synced = try await store.fetch(RecordQuery(scope: .everySynced)).records
		let local = try await store.fetch(RecordQuery(scope: .everyDeviceLocal)).records
		return (synced + local).map(\.body.kind).sorted()
	}
}
