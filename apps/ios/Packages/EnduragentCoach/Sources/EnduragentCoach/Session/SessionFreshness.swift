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
		let dailyDue = lastAt < mostRecentReset(at: settings.dailyResetHour, before: now, in: zone)
		if dailyDue, now.timeIntervalSince(lastAt) >= dailyResetGrace.timeInterval {
			return .reset(.daily)
		}
		if case .after(let minutes) = settings.idleReset,
			now > lastAt.addingTimeInterval(TimeInterval(minutes) * 60)
		{
			return .reset(.idle)
		}
		return dailyDue ? .deferredDailyReset : .fresh
	}

	package static func mostRecentReset(
		at hour: DailyResetHour, before now: Date, in zone: IANATimeZone
	) -> Date {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = zone.timeZone
		guard let today = calendar.date(bySettingHour: hour.hour, minute: 0, second: 0, of: now)
		else {
			fatalError("Cannot resolve the daily reset hour in the athlete's calendar")
		}
		guard now < today else { return today }
		guard let previousDay = calendar.date(byAdding: .day, value: -1, to: now),
			let yesterday = calendar.date(
				bySettingHour: hour.hour, minute: 0, second: 0, of: previousDay)
		else {
			fatalError("Cannot resolve the previous daily reset in the athlete's calendar")
		}
		return yesterday
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
