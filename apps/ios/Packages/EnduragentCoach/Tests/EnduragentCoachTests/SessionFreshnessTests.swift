import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct SessionFreshnessTests {
	private let amsterdam = amsterdamZone

	private func at(_ local: String) throws -> Date {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime]
		return try #require(formatter.date(from: local))
	}

	private func evaluate(
		last: LastExchange, now: String, settings: SessionSettings = .npmDefaults
	) throws -> Freshness {
		SessionFreshness.evaluate(
			last: last, now: try at(now), zone: amsterdam, settings: settings)
	}

	@Test func noEarlierExchangeIsFresh() throws {
		#expect(try evaluate(last: .none, now: "1998-06-16T04:20:00+02:00") == .fresh)
	}

	@Test func dailyResetDefersUnderThirtyMinutes() throws {
		let last = LastExchange.at(try at("1998-06-16T03:50:00+02:00"))
		#expect(try evaluate(last: last, now: "1998-06-16T04:10:00+02:00") == .deferredDailyReset)
		let almost = LastExchange.at(try at("1998-06-16T03:40:01+02:00"))
		#expect(try evaluate(last: almost, now: "1998-06-16T04:10:00+02:00") == .deferredDailyReset)
	}

	@Test func dailyResetAtFortyMinutesResets() throws {
		let last = LastExchange.at(try at("1998-06-16T03:40:00+02:00"))
		#expect(try evaluate(last: last, now: "1998-06-16T04:20:00+02:00") == .reset(.daily))
		let exactly = LastExchange.at(try at("1998-06-16T03:50:00+02:00"))
		#expect(try evaluate(last: exactly, now: "1998-06-16T04:20:00+02:00") == .reset(.daily))
		let overnight = LastExchange.at(try at("1998-06-15T20:00:00+02:00"))
		#expect(try evaluate(last: overnight, now: "1998-06-16T09:00:00+02:00") == .reset(.daily))
	}

	@Test func exchangeAfterTheResetHourIsFresh() throws {
		let last = LastExchange.at(try at("1998-06-16T04:00:00+02:00"))
		#expect(try evaluate(last: last, now: "1998-06-16T23:59:00+02:00") == .fresh)
		let beforeToday = LastExchange.at(try at("1998-06-16T01:00:00+02:00"))
		#expect(try evaluate(last: beforeToday, now: "1998-06-16T03:59:00+02:00") == .fresh)
	}

	@Test func malformedTimestampResetsWithoutDeferral() throws {
		#expect(try evaluate(last: .malformed, now: "1998-06-16T04:00:30+02:00") == .reset(.daily))
		let idle = try SessionSettings.npmDefaults.replacing(.idleReset, with: "5")
		#expect(
			try evaluate(last: .malformed, now: "1998-06-16T12:00:00+02:00", settings: idle)
				== .reset(.daily))
	}

	@Test func idleResetNeverDefers() throws {
		let idle = try SessionSettings.npmDefaults.replacing(.idleReset, with: "5")
		let last = LastExchange.at(try at("1998-06-16T10:00:00+02:00"))
		#expect(
			try evaluate(last: last, now: "1998-06-16T10:06:00+02:00", settings: idle)
				== .reset(.idle))
		#expect(
			try evaluate(last: last, now: "1998-06-16T10:05:00+02:00", settings: idle) == .fresh)
	}

	@Test func idleZeroIsOff() throws {
		let off = try SessionSettings.npmDefaults.replacing(.idleReset, with: "0")
		let last = LastExchange.at(try at("1998-06-16T04:30:00+02:00"))
		#expect(
			try evaluate(last: last, now: "1998-06-16T23:30:00+02:00", settings: off) == .fresh)
	}

	@Test func resetHourAndZoneComeFromTheSettings() throws {
		let tokyo = try SessionSettings.npmDefaults.replacing(.timeZone, with: "Asia/Tokyo")
			.replacing(.dailyResetHour, with: "6")
		let zone = AthleteCalendar(
			clock: FixedClock(now: "1998-06-16T00:00:00Z", timeZone: "Europe/Amsterdam")
		).zone(for: tokyo.timeZone)
		#expect(zone.identifier == "Asia/Tokyo")
		let last = LastExchange.at(try at("1998-06-15T20:50:00Z"))
		#expect(
			SessionFreshness.evaluate(
				last: last, now: try at("1998-06-15T21:20:00Z"), zone: zone, settings: tokyo)
				== .reset(.daily))
		#expect(
			SessionFreshness.evaluate(
				last: last, now: try at("1998-06-15T21:20:00Z"), zone: amsterdam, settings: tokyo)
				== .fresh)
	}

	@Test(arguments: [
		("1998-03-29T03:30:00+02:00", "1998-03-28T04:00:00+01:00"),
		("1998-10-26T03:00:00+01:00", "1998-10-25T04:00:00+01:00"),
		("1998-10-25T03:20:00+01:00", "1998-10-24T04:00:00+02:00"),
	])
	func previousDayResetIsFourLocalAcrossDST(now: String, expected: String) throws {
		let reset = SessionFreshness.mostRecentReset(
			at: .npmDefault, before: try at(now), in: amsterdam)
		#expect(reset == (try at(expected)))
	}

	@Test(arguments: [
		("1998-03-29T01:30:00+01:00", "1998-03-28T02:00:00+01:00"),
		("1998-03-29T03:00:00+02:00", "1998-03-29T03:00:00+02:00"),
		("1998-03-29T03:30:00+02:00", "1998-03-29T03:00:00+02:00"),
		("1998-03-30T01:00:00+02:00", "1998-03-29T03:00:00+02:00"),
	])
	func missingResetHourUsesTheFirstValidInstant(now: String, expected: String) throws {
		let reset = SessionFreshness.mostRecentReset(
			at: try DailyResetHour(2), before: try at(now), in: amsterdam)
		#expect(reset == (try at(expected)))
	}

	@Test(arguments: [
		("1998-10-25T01:30:00+02:00", "1998-10-24T02:00:00+02:00"),
		("1998-10-25T02:30:00+02:00", "1998-10-25T02:00:00+02:00"),
		("1998-10-25T02:30:00+01:00", "1998-10-25T02:00:00+02:00"),
		("1998-10-26T01:00:00+01:00", "1998-10-25T02:00:00+02:00"),
	])
	func repeatedResetHourUsesTheFirstOccurrence(now: String, expected: String) throws {
		let reset = SessionFreshness.mostRecentReset(
			at: try DailyResetHour(2), before: try at(now), in: amsterdam)
		#expect(reset == (try at(expected)))
	}
}
