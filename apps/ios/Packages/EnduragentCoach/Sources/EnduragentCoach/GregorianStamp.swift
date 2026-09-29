import Foundation

package enum GregorianStamp {
	package static func day(_ date: Date, timeZone: TimeZone) -> String {
		date.formatted(dayStyle(timeZone: timeZone))
	}

	package static func minuteUTC(_ date: Date) -> String {
		let body = date.formatted(
			Date.VerbatimFormatStyle(
				format:
					"\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
				locale: Locale(identifier: "en_US_POSIX"),
				timeZone: .gmt,
				calendar: gregorian
			)
		)
		return body + " UTC"
	}

	package static func weekdayMinute(_ date: Date, in zone: TimeZone) -> String {
		let body = date.formatted(
			Date.VerbatimFormatStyle(
				format:
					"\(weekday: .abbreviated) \(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
				locale: Locale(identifier: "en_US_POSIX"),
				timeZone: zone,
				calendar: gregorian
			)
		)
		return body + " " + zone.identifier
	}

	package static func isoMillis(_ date: Date) -> String {
		date.formatted(
			Date.VerbatimFormatStyle(
				format:
					"\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)T\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))Z",
				locale: Locale(identifier: "en_US_POSIX"),
				timeZone: .gmt,
				calendar: gregorian
			)
		)
	}

	private static let gregorian = Calendar(identifier: .gregorian)

	private static func dayStyle(timeZone: TimeZone) -> Date.VerbatimFormatStyle {
		Date.VerbatimFormatStyle(
			format: "\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)",
			locale: Locale(identifier: "en_US_POSIX"),
			timeZone: timeZone,
			calendar: gregorian
		)
	}
}
