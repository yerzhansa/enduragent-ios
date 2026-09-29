import Foundation

package enum GregorianStamp {
	package static func day(_ date: Date, timeZone: TimeZone) -> String {
		date.formatted(
			style("\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)", in: timeZone))
	}

	package static func minuteUTC(_ date: Date) -> String {
		date.formatted(
			style(
				"\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
				in: .gmt)) + " UTC"
	}

	package static func weekdayMinute(_ date: Date, in zone: TimeZone) -> String {
		date.formatted(
			style(
				"\(weekday: .abbreviated) \(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
				in: zone)) + " " + zone.identifier
	}

	package static func isoMillis(_ date: Date) -> String {
		date.formatted(
			style(
				"\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)T\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))Z",
				in: .gmt))
	}

	private static let gregorian = Calendar(identifier: .gregorian)

	private static func style(_ format: Date.FormatString, in zone: TimeZone)
		-> Date.VerbatimFormatStyle
	{
		Date.VerbatimFormatStyle(
			format: format, locale: Locale(identifier: "en_US_POSIX"), timeZone: zone,
			calendar: gregorian)
	}
}
