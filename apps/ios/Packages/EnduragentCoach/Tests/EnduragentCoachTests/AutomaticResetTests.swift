import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct AutomaticResetTests {
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	func coach(at clock: FixedClock, over log: (any RecordLog)? = nil) -> Coach {
		makeCoach(transport: transport, store: log ?? store, clock: clock)
	}

	func answer(_ replies: String...) {
		transport.script = replies.flatMap { [ScriptedEvent.text($0), .finish(reason: .stop)] }
	}

	func records(_ scope: RecordQuery.Scope) async throws -> [AthleteRecord] {
		try await store.fetch(RecordQuery(scope: scope, chatId: .main)).records
			.sorted { $0.hlc < $1.hlc }
	}

	@Test func overnightBreakOpensANewConversationAtTheTurnThatCrossedIt() async throws {
		let clock = FixedClock(now: "1998-06-15T20:00:00+02:00", timeZone: "Europe/Amsterdam")
		let coach = coach(at: clock)
		answer("Two rides.", "Rest today.")
		_ = try await coach.sendAndSettle("How was my week?")
		clock.advance(by: 13 * 3_600)
		_ = try await coach.sendAndSettle("What now?")
		let asked = try await records(.synced([.userMessage])).map(\.ulid)
		let answered = try await records(.synced([.turnSettled])).map(\.ulid)
		try #require(asked.count == 2 && answered.count == 2)
		#expect(
			try await records(.synced([.windowStart])).map(\.body) == [
				.synced(
					.windowStart(
						WindowStartBody(
							chatId: .main, firstIncludedUlid: asked[1], reason: .reset(.daily))))
			])
		#expect(
			try await records(.deviceLocal([.flushPending])).map(\.body) == [
				.deviceLocal(
					.flushPending(
						FlushPendingBody(
							chatId: .main, trigger: .staleReset,
							messageUlids: [asked[0], answered[0]])))
			])
		#expect(await coach.transcript(.main) == ["What now?", "Rest today."])
		let archived = try await coach.history()
		#expect(archived.map(\.reason) == [.closedAfterBreak])
		#expect(archived.first?.turns.map(\.athleteText) == ["How was my week?"])
	}

	@Test func recentExchangeAcrossTheResetHourKeepsTheConversation() async throws {
		let clock = FixedClock(now: "1998-06-16T03:50:00+02:00", timeZone: "Europe/Amsterdam")
		let coach = coach(at: clock)
		answer("Two rides.", "Rest today.")
		_ = try await coach.sendAndSettle("How was my week?")
		clock.advance(by: 20 * 60)
		_ = try await coach.sendAndSettle("What now?")
		#expect(try await records(.synced([.windowStart])).isEmpty)
		#expect(
			await coach.transcript(.main) == [
				"How was my week?", "Two rides.", "What now?", "Rest today.",
			])
		#expect(try await coach.history().isEmpty)
	}

	@Test func theResetNoticeShowsOnceAndTheModelHearsOfItOnlyOnTheResetTurn() async throws {
		let clock = FixedClock(now: "1998-06-16T03:40:00+02:00", timeZone: "Europe/Amsterdam")
		let coach = coach(at: clock)
		answer("Two rides.", "Rest today.", "Easy spin.")
		_ = try await coach.sendAndSettle("How was my week?")
		#expect(await coach.currentSnapshot(.main)?.opening == .continuing)
		clock.advance(by: 40 * 60)
		_ = try await coach.sendAndSettle("What now?")
		let reset = try #require(await coach.currentSnapshot(.main))
		#expect(reset.opening == .afterAutomaticReset(.daily))
		#expect(reset.opening.notice == Catalog.coachHistoryReset)
		#expect(!reset.opening.showsWelcome)
		_ = try await coach.sendAndSettle("And tomorrow?")
		#expect(await coach.currentSnapshot(.main)?.opening == .afterAutomaticReset(.daily))
		#expect(
			await self.coach(at: clock).currentSnapshot(.main)?.opening
				== .afterAutomaticReset(.daily))
		let marker =
			"Previous session archived at 1998-06-16T02:20:00.000Z. Briefly disclose this before answering."
		let chats = sent(.chatAttempt, by: transport).map { $0.messages.map(\.content) }
		try #require(chats.count == 3)
		#expect(chats.map { $0.filter { $0 == marker }.count } == [0, 1, 0])
		#expect(chats[1].suffix(1).first?.hasPrefix("What now?") == true)
		#expect(!chats[1].contains("How was my week?"))
	}

	@Test func idleResetFollowsTheStoredSetting() async throws {
		let clock = FixedClock(now: "1998-06-16T10:00:00+02:00", timeZone: "Europe/Amsterdam")
		let coach = coach(at: clock)
		try await coach.setSession(SessionSettings.npmDefaults.replacing(.idleReset, with: "30"))
		answer("Two rides.", "Rest today.", "Easy spin.")
		_ = try await coach.sendAndSettle("How was my week?")
		clock.advance(by: 29 * 60)
		_ = try await coach.sendAndSettle("What now?")
		#expect(try await records(.synced([.windowStart])).isEmpty)
		clock.advance(by: 31 * 60)
		_ = try await coach.sendAndSettle("And tomorrow?")
		let boundaries = try await records(.synced([.windowStart])).map(\.body)
		let asked = try await records(.synced([.userMessage])).map(\.ulid)
		#expect(
			boundaries == [
				.synced(
					.windowStart(
						WindowStartBody(
							chatId: .main, firstIncludedUlid: asked[2], reason: .reset(.idle))))
			])
		#expect(await coach.currentSnapshot(.main)?.opening == .afterAutomaticReset(.idle))
		#expect(try await coach.history().map(\.reason) == [.closedAfterBreak])
		#expect(await coach.transcript(.main) == ["And tomorrow?", "Easy spin."])
	}

	@Test func aResetThatCannotBeSavedAnswersInTheSameConversation() async throws {
		let clock = FixedClock(now: "1998-06-15T20:00:00+02:00", timeZone: "Europe/Amsterdam")
		let log = FaultInjectingRecordLog(wrapping: store)
		let coach = coach(at: clock, over: log)
		answer("Two rides.", "Rest today.")
		_ = try await coach.sendAndSettle("How was my week?")
		log.failAppends(ofKind: SyncedKind.windowStart)
		clock.advance(by: 13 * 3_600)
		_ = try await coach.sendAndSettle("What now?")
		#expect(
			await coach.transcript(.main) == [
				"How was my week?", "Two rides.", "What now?", "Rest today.",
			])
		#expect(await coach.currentSnapshot(.main)?.opening == .continuing)
		#expect(
			coach.diagnostics.entries.contains {
				$0.event == .automaticResetUnsaved(.main, .rejectedBatch)
			})
	}
}
