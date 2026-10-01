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
		await #expect(throws: URLError(.timedOut)) {
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

	@Test func lostAnswerCanBeConfirmedThroughThePresentedCoachReview() async throws {
		let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		client.loseCalendarSaveAnswerOnce = true
		let model = FakeModelTransport()
		let coach = await makeCoach(transport: model, intervals: client, store: InMemoryRecordLog())
		let (_, token) = try await DurableCalendarWriteTests().proposal(on: coach, model: model)
		_ = await coach.decide(.approve(token), in: .main)
		await coach.stop(.main)
		let unknown = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(unknown.notice?.key == Catalog.reviewWritePending)
		#expect(unknown.controls == .checkAgain(unknown.ref))
		try #require(client.events.count == 1)
		let event = try #require(client.events.first)
		#expect(
			await coach.decide(.checkAgain(unknown.ref), in: .main)
				== .applied([
					ReviewReceipt(index: 0, result: .confirmed(eventId: String(event.id.rawValue)))
				]))
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		#expect(client.events == [event])
		#expect(
			client.calls.filter {
				if case .createEvent = $0 { return true }
				return false
			}.count == 1)
	}

	@Test(arguments: [false, true])
	func calendarReadFaultIsConsumedOnlyByTheNextEventRead(fetchFirst: Bool) async throws {
		let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let approval = draft()
		let event = try await client.createChatEvent(approval)
		client.failCalendarReadOnce = true
		#expect(try await client.fetchAthlete().name == "Ada")
		#expect(
			try await client.fetchWellness(oldest: approval.date, newest: approval.date).isEmpty)
		#expect(
			try await client.fetchActivities(oldest: approval.date, newest: approval.date).isEmpty)
		let activity = try #require(ActivityID(rawValue: "42"))
		_ = try await client.fetchActivity(id: activity)
		_ = try await client.fetchStreams(id: activity)
		await #expect(throws: URLError(.notConnectedToInternet)) {
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
