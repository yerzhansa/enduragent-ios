import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CalendarProofHookTests {
	@Test func fakeCalendarStoresTheFullApprovalAndUpsertsItsIdentity() async throws {
		let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let (approval, identity) = add()
		let first = await client.write(.create(approval, identity: identity))
		let second = await client.write(.create(approval, identity: identity))
		let events = try await client.listEvents(in: .day(approval.date))
		try #require(events.count == 1)
		let event = try #require(events.first)
		#expect(first == .saved(event))
		#expect(second == .saved(event))
		#expect(event.uid == identity.uid)
		#expect(event.externalId == identity.externalID)
		#expect(event.tags == [IntervalsPolicy.coachTag])
		#expect(event.coachCreated)
		#expect(holds(approval, event))
		#expect(try await client.fetchEvent(id: event.id) == event)
	}

	@Test func lostAnswerStoresTheFullApprovalBeforeFailingOnce() async throws {
		let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let (approval, identity) = add()
		client.loseCalendarSaveAnswerOnce = true
		#expect(await client.write(.create(approval, identity: identity)) == .lost(.transport))
		let stored = try await client.listEvents(in: .day(approval.date))
		try #require(stored.count == 1)
		let event = try #require(stored.first)
		#expect(holds(approval, event))
		#expect(event.uid == identity.uid)
		#expect(event.externalId == identity.externalID)
		#expect(event.tags == [IntervalsPolicy.coachTag])
		#expect(event.coachCreated)
		#expect(await client.write(.create(approval, identity: identity)) == .saved(event))
		#expect(try await client.listEvents(in: .day(approval.date)) == stored)
	}

	@Test(arguments: [false, true])
	func calendarReadFaultIsConsumedOnlyByTheNextEventRead(fetchFirst: Bool) async throws {
		let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let (approval, identity) = add()
		guard case .saved(let event?) = await client.write(.create(approval, identity: identity))
		else {
			Issue.record("expected the add to be saved")
			return
		}
		client.failCalendarReadOnce = true
		#expect(try await client.profile().name == "Ada")
		#expect(
			try await client.wellness(in: .day(approval.date)).isEmpty)
		#expect(try await client.activities(in: .day(approval.date)).total == 0)
		let activity = try #require(ActivityID(rawValue: "42"))
		#expect(try await client.activity(activity) == .notFound)
		#expect(
			try await client.streams(of: activity, channels: .standard).gaps
				== [.unanswered: StreamChannels.standard.names])
		await #expect(
			throws: IntervalsError(
				code: "network", details: "intervals.icu could not be reached (URLError -1009).")
		) {
			if fetchFirst {
				_ = try await client.fetchEvent(id: event.id)
			} else {
				_ = try await client.listEvents(in: .day(approval.date))
			}
		}
		#expect(try await client.fetchEvent(id: event.id) == event)
		#expect(
			try await client.listEvents(in: .day(approval.date)) == [event])
	}

	private func add() -> (CalendarPayload, CalendarWriteID) {
		(
			CalendarPayload(
				date: "1998-06-16", type: .ride, name: "Endurance",
				description: "- 10m 60%\n- 40m 70%\n- 10m 60%", movingTime: 3600,
				trainingLoad: 52),
			CalendarWriteID()
		)
	}

	private func holds(_ approval: CalendarPayload, _ event: CalendarEvent) -> Bool {
		event.name == approval.name && event.description == approval.description
			&& event.type == approval.type.rawValue && event.category == "WORKOUT"
			&& event.startDateLocal == "\(approval.date.rawValue)T00:00:00"
			&& event.movingTime == approval.movingTime
			&& event.trainingLoad == approval.trainingLoad
	}
}
