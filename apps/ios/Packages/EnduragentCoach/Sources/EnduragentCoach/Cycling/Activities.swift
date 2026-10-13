import Foundation

package enum ActivityField: Hashable, Sendable, CaseIterable {
	case duration
	case distance
	case load
	case intensity
	case averagePower
	case weightedPower
	case averageHeartRate
	case maxHeartRate
	case ftp
	case elevationGain
}

package struct LocalStart: Sendable, Equatable, Comparable {
	package static let secondsPerDay = 86_400

	package let date: CivilDate
	package let secondOfDay: Int?

	package init?(date: CivilDate, secondOfDay: Int?) {
		if let secondOfDay, !(0..<Self.secondsPerDay).contains(secondOfDay) { return nil }
		self.date = date
		self.secondOfDay = secondOfDay
	}

	package static func < (lhs: LocalStart, rhs: LocalStart) -> Bool {
		if lhs.date != rhs.date { return lhs.date < rhs.date }
		return (lhs.secondOfDay ?? -1) < (rhs.secondOfDay ?? -1)
	}
}

package struct Activity: Sendable, Equatable {
	package let id: ActivityID
	package let name: String?
	package let sport: String?
	package let start: LocalStart
	package let readings: Readings<ActivityField>

	package init(
		id: ActivityID, name: String?, sport: String?, start: LocalStart,
		readings: Readings<ActivityField>
	) {
		self.id = id
		self.name = name
		self.sport = sport
		self.start = start
		self.readings = readings
	}
}

package enum ActivityRow: Sendable, Equatable {
	case activity(Activity)
	case hiddenByStrava
	case unreadable

	package init(
		source: String?, sport: String?, movingTime: Double?, elapsedTime: Double?,
		activity: Activity?
	) {
		let lacksATime = [movingTime, elapsedTime].contains { ($0 ?? -1) < 0 }
		if source == IntervalsPolicy.stravaSource, sport == nil || lacksATime {
			self = .hiddenByStrava
		} else if let activity {
			self = .activity(activity)
		} else {
			self = .unreadable
		}
	}
}

package struct ActivityListing: Sendable, Equatable {
	package let range: ReadRange
	package let activities: [Activity]
	package let hiddenByStrava: Int
	package let unreadable: Int

	package var total: Int { activities.count + hiddenByStrava + unreadable }

	package init(range: ReadRange, rows: [ActivityRow]) {
		var activities: [Activity] = []
		var hiddenByStrava = 0
		var unreadable = 0
		for row in rows {
			switch row {
			case .activity(let activity): activities.append(activity)
			case .hiddenByStrava: hiddenByStrava += 1
			case .unreadable: unreadable += 1
			}
		}
		self.range = range
		self.activities = activities.sorted {
			$0.start == $1.start ? $0.id.rawValue < $1.id.rawValue : $0.start < $1.start
		}
		self.hiddenByStrava = hiddenByStrava
		self.unreadable = unreadable
	}
}
