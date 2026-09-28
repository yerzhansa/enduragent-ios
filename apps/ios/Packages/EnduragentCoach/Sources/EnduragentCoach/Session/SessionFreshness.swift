import Foundation

package enum SessionFreshness {
	package static let dailyResetGrace: Duration = .seconds(30 * 60)

	package static func evaluate(
		last: LastExchange, now: Date, zone: IANATimeZone, settings: SessionSettings
	) -> Freshness {
		let lastAt: Date
		switch last {
		case .none: return .fresh
		case .malformed: return .reset(.daily)
		case .at(let date): lastAt = date
		}
		if lastAt < mostRecentReset(at: settings.dailyResetHour, before: now, in: zone) {
			let recent = now.timeIntervalSince(lastAt) < dailyResetGrace.timeInterval
			return recent ? .deferredDailyReset : .reset(.daily)
		}
		if case .after(let minutes) = settings.idleReset,
			now > lastAt.addingTimeInterval(TimeInterval(minutes) * 60)
		{
			return .reset(.idle)
		}
		return .fresh
	}

	package static func mostRecentReset(
		at hour: DailyResetHour, before now: Date, in zone: IANATimeZone
	) -> Date {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = zone.timeZone
		let offset = TimeInterval(hour.hour) * 3_600
		let today = calendar.startOfDay(for: now).addingTimeInterval(offset)
		guard now < today else { return today }
		return calendar.startOfDay(for: today.addingTimeInterval(-86_400)).addingTimeInterval(
			offset)
	}
}

package enum LastExchange: Sendable, Equatable {
	case none
	case at(Date)
	case malformed
}

package enum Freshness: Sendable, Equatable {
	case fresh
	case deferredDailyReset
	case reset(ResetKind)
}

extension AthleteCalendar {
	package func zone(for setting: SessionTimeZone) -> IANATimeZone {
		switch setting {
		case .device: deviceZone
		case .fixed(let zone): zone
		}
	}
}
