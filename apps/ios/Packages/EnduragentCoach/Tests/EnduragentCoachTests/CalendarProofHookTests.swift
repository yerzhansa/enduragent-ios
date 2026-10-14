import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CalendarProofHookTests {
	@Test func fakeCalendarStoresTheFullApprovalAndUpsertsItsIdentity() async throws {
		let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let approval = draft()
		let first = try await client.createChatEvent(approval)
		let second = try await client.createChatEvent(approval)
		let events = try await client.listEvents(oldest: approval.date, newest: approval.date)
		try #require(events.count == 1)
		let event = try #require(events.first)
		#expect(first.id == second.id)
		#expect(event.uid == approval.writeID?.uid)
		#expect(event.externalId == approval.writeID?.externalID)
		#expect(event.tags == approval.tags)
		#expect(event.coachCreated)
		#expect(approval.matches(event))
		#expect(try await client.fetchEvent(id: event.id) == event)
	}

	@Test func lostAnswerStoresTheFullApprovalBeforeFailingOnce() async throws {
		let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let approval = draft()
		client.loseCalendarSaveAnswerOnce = true
		await #expect(
			throws: IntervalsError(
				code: "network", details: "intervals.icu could not be reached (URLError -1001).")
		) {
			_ = try await client.createChatEvent(approval)
		}
		let stored = try await client.listEvents(oldest: approval.date, newest: approval.date)
		try #require(stored.count == 1)
		let event = try #require(stored.first)
		#expect(approval.matches(event))
		#expect(event.uid == approval.writeID?.uid)
		#expect(event.externalId == approval.writeID?.externalID)
		#expect(event.tags == approval.tags)
		#expect(event.coachCreated)
		let repeated = try await client.createChatEvent(approval)
		#expect(repeated == event)
		#expect(try await client.listEvents(oldest: approval.date, newest: approval.date) == stored)
	}

	@Test(arguments: [false, true])
	func calendarReadFaultIsConsumedOnlyByTheNextEventRead(fetchFirst: Bool) async throws {
		let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let approval = draft()
		let event = try await client.createChatEvent(approval)
		client.failCalendarReadOnce = true
		#expect(try await client.profile().name == "Ada")
		#expect(
			try await client.wellness(in: .day(approval.date)).isEmpty)
		#expect(try await client.activities(in: .day(approval.date)).total == 0)
		let activity = try #require(ActivityID(rawValue: "42"))
		#expect(try await client.activity(activity) == .notFound)
		#expect(
			try await client.streams(of: activity, channels: .standard).unanswered
				== StreamChannels.standard.names)
		await #expect(
			throws: IntervalsError(
				code: "network", details: "intervals.icu could not be reached (URLError -1009).")
		) {
			if fetchFirst {
				_ = try await client.fetchEvent(id: event.id)
			} else {
				_ = try await client.listEvents(oldest: approval.date, newest: approval.date)
			}
		}
		#expect(try await client.fetchEvent(id: event.id) == event)
		#expect(
			try await client.listEvents(oldest: approval.date, newest: approval.date) == [event])
	}

	private func draft() -> ChatCalendarCreate {
		ChatCalendarCreate(
			writeID: CalendarWriteID(), date: "1998-06-16", name: "Endurance",
			description: "- 10m 60%\n- 40m 70%\n- 10m 60%", type: .ride,
			externalId: IntervalsSerializer.chatExternalId(date: "1998-06-16", name: "Endurance"),
			tags: [IntervalsPolicy.coachTag])
	}
}
