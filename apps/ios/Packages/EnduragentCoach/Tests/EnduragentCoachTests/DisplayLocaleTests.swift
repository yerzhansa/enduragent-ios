import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(2))) struct DisplayLocaleTests {
	@Test(arguments: [
		(
			LanguagePreference.fixed(.fr), ["en-US"], "fr_US", LanguageTag.fr, "3/4/2026",
			"1,234.5", "1:05 PM", "mars", "mercredi"
		),
		(
			.automatic, ["ru", "fr", "en"], "en_FR", .fr, "04/03/2026", "1 234,5", "13:05", "mars",
			"mercredi"
		),
		(
			.automatic, ["ru", "fr"], "en_US", .fr, "3/4/2026", "1,234.5", "1:05 PM", "mars",
			"mercredi"
		),
		(
			.automatic, ["ru", "ar"], "fr_FR", .en, "04/03/2026", "1 234,5", "13:05", "March",
			"Wednesday"
		),
		(
			.automatic, ["pt-BR", "pt-PT"], "pt_PT", .ptBR, "04/03/2026", "1234,5", "13:05",
			"março", "quarta-feira"
		),
		(
			.automatic, ["zh-Hant", "zh-Hans"], "zh_Hant_US", .zhHant, "3/4/2026", "1,234.5",
			"1:05 下午",
			"3月", "星期三"
		),
	])
	func regionMatrixThroughSend(
		preference: LanguagePreference, preferred: [String], region: String, language: LanguageTag,
		day: String, decimal: String, time: String, month: String, weekday: String
	) async throws {
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(),
			displayLocale: {
				DisplayLocale(
					preference: $0, preferredLanguages: preferred,
					regionalConventions: Locale(identifier: region))
			})
		try await coach.setLanguage(preference)
		let display = try await coach.observedStatus().displayLocale
		#expect(display.language == language)
		#expect(display.date("2026-03-04", style: .numeric) == day)
		let named = display.date("2026-03-04", style: .named)
		#expect(named.contains(month))
		#expect(named.contains(weekday))
		#expect(display.number(1234.5, precision: .tenths) == decimal)
		let instant = FixedClock(now: "2026-03-04T13:05:00Z", timeZone: "UTC").now
		#expect(display.clock(instant, in: .gmt).replacingOccurrences(of: " ", with: " ") == time)
		let summary = ReviewSummary.createWorkout(name: "Copied ride", date: "2026-03-04")
		#expect(summary.sentence(in: display).contains(day))
		#expect(summary.sentence(in: display).contains("Copied ride"))
		let notice = AthleteNotices.notice(
			for: .model(.rateLimited(retryAfter: .seconds(74_100))), turn: nil, waiting: false)
		#expect(notice.sentence(in: display).contains(display.integer(1235)))
		transport.respond = ScriptedReply.sequence(
			[.text("Reply"), .finish(reason: .stop)], otherwise: transport.respond)
		_ = try await coach.sendAndSettle("English text and cited title remain unchanged")
		let system = try #require(sent(.chatAttempt, by: transport).last?.messages.first?.content)
		let lines = system.components(separatedBy: "\n").filter {
			$0.hasPrefix("For prose, use iPhone region ")
		}
		try #require(lines.count == 1)
		#expect(lines[0].contains("region \(display.regionalConventions.region?.identifier ?? "")"))
		#expect(lines[0].contains(day))
		#expect(lines[0].contains(decimal))
		#expect(system.contains("month and weekday words follow \(language.englishName)"))
	}

	@Test func effectiveConventionsAndCivilDays() throws {
		let frenchUS = displayLocale(.fr, region: "fr_US")
		#expect(frenchUS.date("2026-03-04", style: .named) == "mercredi, mars 4, 2026")
		#expect(frenchUS == displayLocale(.fr, region: "en_US"))
		let frenchFrance = displayLocale(.fr, region: "fr_FR")
		#expect(frenchFrance.date("2026-03-04", style: .named) == "mercredi 4 mars 2026")
		#expect(frenchUS != frenchFrance)
		let override = displayLocale(.fr, region: "en_US@hours=h23")
		#expect(override != frenchUS)
		let clock = FixedClock(now: "2026-03-04T13:05:00Z", timeZone: "UTC")
		#expect(override.clock(clock.now, in: .gmt) == "13:05")
		let west = try #require(TimeZone(identifier: "America/Los_Angeles"))
		#expect(override.clock(clock.now, in: west) == "05:05")
		#expect(frenchUS.date("2026-01-01", style: .numeric) == "1/1/2026")
		#expect(frenchUS.date("2026-12-31", style: .numeric) == "12/31/2026")
		#expect(
			displayLocale(.fr, region: "en_US@calendar=buddhist").date(
				"2026-03-04", style: .numeric) == "3/4/2569 E. B.")
		#expect(frenchUS.number(12.5, precision: .whole) == "13")
		#expect(frenchFrance.number(-12.5, precision: .whole) == "-13")
		#expect(frenchFrance.number(nil, precision: .whole) == "—")
	}

	@Test func refreshFollowsThePhoneAndKeepsFixedWords() async throws {
		let phone = DisplayPhone()
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), displayLocale: phone.resolve)
		let statuses = await coach.observeStatus()
		#expect(try await statuses.status { $0.displayLocale.language == .fr } != nil)
		phone.change(languages: ["zh-Hant", "fr"], region: "fr_FR")
		await coach.refreshDisplayLocale()
		let changed = try #require(
			try await statuses.status { $0.displayLocale.language == .zhHant })
		#expect(changed.displayLocale.date("2026-03-04", style: .numeric) == "04/03/2026")
		try await coach.setLanguage(.fixed(.fr))
		phone.change(languages: ["en"], region: "en_US@hours=h23")
		await coach.refreshDisplayLocale()
		let fixed = try #require(
			try await statuses.status {
				$0.language == .fixed(.fr)
					&& $0.displayLocale.regionalConventions.hourCycle == .zeroToTwentyThree
			})
		#expect(fixed.displayLocale.language == .fr)
		#expect(fixed.displayLocale.date("2026-03-04", style: .numeric) == "3/4/2026")
	}

	@Test func attemptFreezesBeforeAccessSuspendsAndNextAttemptResolvesAgain() async throws {
		let phone = DisplayPhone()
		let store = ImportingRecordLog()
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Reply"), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, store: store, displayLocale: phone.resolve)
		let gate = store.holdRead(scope: .deviceLocal([.providerConsent]))
		defer { gate.release() }
		let sending = Task { try await coach.sendAndSettle("First") }
		try #require(
			try await beforeDeadline(within: .hangGuard) { await gate.waitUntilParked() } != nil)
		phone.change(languages: ["en"], region: "fr_FR")
		gate.release()
		_ = try await sending.value
		let first = try #require(sent(.chatAttempt, by: transport).last?.messages.first?.content)
		#expect(first.contains("month and weekday words follow French"))
		#expect(first.contains("iPhone region US"))
		transport.respond = ScriptedReply.sequence(
			[.text("Reply"), .finish(reason: .stop)], otherwise: transport.respond)
		_ = try await coach.sendAndSettle("Second")
		let second = try #require(sent(.chatAttempt, by: transport).last?.messages.first?.content)
		#expect(second.contains("month and weekday words follow English"))
		#expect(second.contains("iPhone region FR"))
	}
}

final class DisplayPhone: Sendable {
	private let state = Mutex((languages: ["fr"], region: Locale(identifier: "en_US")))

	func resolve(_ preference: LanguagePreference) -> DisplayLocale {
		state.withLock {
			DisplayLocale(
				preference: preference, preferredLanguages: $0.languages,
				regionalConventions: $0.region)
		}
	}

	func change(languages: [String], region: String) {
		state.withLock { $0 = (languages, Locale(identifier: region)) }
	}
}
