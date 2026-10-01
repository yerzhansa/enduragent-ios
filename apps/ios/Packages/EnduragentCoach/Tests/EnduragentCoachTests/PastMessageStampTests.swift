import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PastMessageStampTests {
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	@Test func aStampNamesWeekdayDateMinuteAndZone() throws {
		let tokyo = try #require(IANATimeZone(identifier: "Asia/Tokyo"))
		let sent = Date(timeIntervalSince1970: 897_948_750)
		#expect(
			PromptAssembly.wireMessage(
				from: ChatMessage(
					author: .athlete(sent: sent, timeZone: tokyo), text: "Intervals today.")
			)
				== WireMessage(
					role: .user, content: "[Tue 1998-06-16 07:12 Asia/Tokyo] Intervals today.",
					toolCalls: [], toolCallId: nil))
		#expect(
			PromptAssembly.wireMessage(
				from: ChatMessage(
					author: .athlete(sent: sent, timeZone: tokyo), text: "[Tue] my own brackets")
			).content == "[Tue 1998-06-16 07:12 Asia/Tokyo] [Tue] my own brackets")
		#expect(
			PromptAssembly.wireMessage(
				from: ChatMessage(author: .coach, text: "Keep it easy.\nSpin only."))
				== WireMessage(
					role: .assistant, content: "Keep it easy.\nSpin only.", toolCalls: [],
					toolCallId: nil))
	}

	@Test func aConversationAcrossMidnightReachesTheModelWithDatedAthleteMessages() async throws {
		let clock = FixedClock(now: "1998-06-15T23:50:00+02:00", timeZone: "Europe/Amsterdam")
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		transport.script = [
			.text("Good, keep them at 105%."), .finish(reason: .stop),
			.text("Expected after yesterday's intervals."), .finish(reason: .stop),
		]
		_ = try await coach.sendAndSettle("I'm doing intervals today.")
		clock.advance(by: 20 * 60)
		_ = try await coach.sendAndSettle("My legs are sore.")
		let chat = try #require(sent(.chatAttempt, by: transport).last)
		#expect(
			chat.messages.dropFirst().map(\.content) == [
				"[Mon 1998-06-15 23:50 Europe/Amsterdam] I'm doing intervals today.",
				"Good, keep them at 105%.",
				"My legs are sore.\nCurrent time: Tuesday, June 16th, 1998 - 00:10 (Europe/Amsterdam) / 1998-06-15 22:10 UTC",
			])
		#expect(chat.messages.dropFirst().map(\.role) == [.user, .assistant, .user])
		#expect(chat.messages.first?.content.contains("start with a bracketed send time") == true)
		transport.flushScript = [.finish(reason: .stop)]
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let flush = try #require(sent(.memoryFlush, by: transport).last)
		#expect(
			flush.messages.dropFirst().dropLast().map(\.content) == [
				"[Mon 1998-06-15 23:50 Europe/Amsterdam] I'm doing intervals today.",
				"Good, keep them at 105%.",
				"[Tue 1998-06-16 00:10 Europe/Amsterdam] My legs are sore.",
				"Expected after yesterday's intervals.",
			])
		#expect(flush.messages.last?.content.contains("start with a bracketed send time") == true)
	}

	@Test func stampsUseTheZoneTheMessageWasSentIn() async throws {
		let amsterdam = FixedClock(now: "1998-06-15T20:00:00+02:00", timeZone: "Europe/Amsterdam")
		transport.script = [
			.text("Good, keep them at 105%."), .finish(reason: .stop),
			.text("Expected after yesterday's intervals."), .finish(reason: .stop),
		]
		_ = try await makeCoach(transport: transport, store: store, clock: amsterdam)
			.sendAndSettle("I'm doing intervals today.")
		let tokyo = FixedClock(now: "1998-06-16T03:10:00+09:00", timeZone: "Asia/Tokyo")
		let coach = await makeCoach(transport: transport, store: store, clock: tokyo)
		_ = try await coach.sendAndSettle("My legs are sore.")
		let chat = try #require(sent(.chatAttempt, by: transport).last)
		#expect(
			chat.messages.dropFirst().first?.content
				== "[Mon 1998-06-15 20:00 Europe/Amsterdam] I'm doing intervals today.")
		transport.flushScript = [.finish(reason: .stop)]
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let flush = try #require(sent(.memoryFlush, by: transport).last)
		#expect(
			flush.messages.dropFirst().dropLast().map(\.content) == [
				"[Mon 1998-06-15 20:00 Europe/Amsterdam] I'm doing intervals today.",
				"Good, keep them at 105%.",
				"[Tue 1998-06-16 03:10 Asia/Tokyo] My legs are sore.",
				"Expected after yesterday's intervals.",
			])
	}

	@Test func aClockFromAnotherDeviceDoesNotMoveTheStamp() async throws {
		let clock = FixedClock(now: "1998-06-15T20:00:00+02:00", timeZone: "Europe/Amsterdam")
		let ahead = clock.now.addingTimeInterval(3600)
		let ipad = DeviceID(rawValue: "ipad")
		let remote = TurnID(ulid: ULID.generate(at: ahead))
		try await seed(
			store,
			[
				storedRecord(
					device: ipad, wall: Int64(ahead.timeIntervalSince1970 * 1000),
					ulid: remote.ulid,
					body: .synced(sampleUser(chatId: .main, text: "From my iPad", turn: remote))),
				storedRecord(
					device: ipad, wall: Int64(ahead.timeIntervalSince1970 * 1000) + 1,
					ulid: ULID.generate(at: ahead.addingTimeInterval(1)),
					body: .synced(sampleReply(chatId: .main, turn: remote, text: "Noted."))),
			])
		transport.script = [
			.text("Good."), .finish(reason: .stop), .text("Rest."), .finish(reason: .stop),
		]
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		_ = try await coach.sendAndSettle("Local question")
		_ = try await coach.sendAndSettle("Legs sore?")
		let chat = try #require(sent(.chatAttempt, by: transport).last)
		#expect(
			chat.messages.map(\.content).contains(
				"[Mon 1998-06-15 20:00 Europe/Amsterdam] Local question"))
	}
}
