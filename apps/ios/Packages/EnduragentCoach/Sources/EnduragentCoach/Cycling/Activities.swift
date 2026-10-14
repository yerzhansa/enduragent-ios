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
			$0.start == $1.start ? $0.id.rawValue < $1.id.rawValue : $0.start > $1.start
		}
		self.hiddenByStrava = hiddenByStrava
		self.unreadable = unreadable
	}
}

package struct ActivityLap: Sendable, Equatable {
	package let number: Int
	package let label: String?
	package let kind: String?
	package let readings: Readings<ActivityField>

	package init(number: Int, label: String?, kind: String?, readings: Readings<ActivityField>) {
		self.number = number
		self.label = label
		self.kind = kind
		self.readings = readings
	}
}

package enum Laps: Sendable, Equatable {
	case notSupplied
	case recorded([ActivityLap])
}

package enum ActivityDetailField: Hashable, Sendable, CaseIterable {
	case perceivedExertion
	case feel
	case averageCadence
	case averageSpeed
	case maxSpeed
	case calories
	case work
	case variabilityIndex
	case efficiencyFactor
	case decoupling
}

package struct ZoneSeconds: Sendable, Equatable {
	package let zone: String
	package let seconds: Int

	package init(zone: String, seconds: Int) {
		self.zone = zone
		self.seconds = seconds
	}
}

package struct ActivityDetailExtras: Sendable, Equatable {
	package let notes: String?
	package let indoor: Bool?
	package let readings: Readings<ActivityDetailField>
	package let powerZoneSeconds: [ZoneSeconds]
	package let heartRateZoneSeconds: [Int]

	package init(
		notes: String? = nil, indoor: Bool? = nil,
		readings: Readings<ActivityDetailField> = Readings([:]),
		powerZoneSeconds: [ZoneSeconds] = [], heartRateZoneSeconds: [Int] = []
	) {
		self.notes = notes
		self.indoor = indoor
		self.readings = readings
		self.powerZoneSeconds = powerZoneSeconds
		self.heartRateZoneSeconds = heartRateZoneSeconds
	}
}

package struct ActivityDetail: Sendable, Equatable {
	package let activity: Activity
	package let extras: ActivityDetailExtras
	package let laps: Laps

	package init(
		asked: ActivityID, activity: Activity, extras: ActivityDetailExtras, laps: Laps
	) throws(IntervalsError) {
		guard activity.id == asked else { throw IntervalsError.activityMismatch(asked: asked) }
		self.activity = activity
		self.extras = extras
		self.laps = laps
	}
}

extension IntervalsError {
	package static func activityMismatch(asked: ActivityID) -> IntervalsError {
		IntervalsError(
			code: "activity_mismatch",
			details:
				"intervals.icu answered with a different activity than \(asked.rawValue). Nothing from that answer is shown."
		)
	}
}

package enum ActivityDetailRead: Sendable, Equatable {
	case found(ActivityDetail)
	case notFound
	case hiddenByStrava
}

package struct StreamSamples: Sendable, Equatable {
	package let channel: String
	package let values: [Double?]

	package init(channel: String, values: [Double?]) {
		self.channel = channel
		self.values = values
	}
}

package struct ChannelSummary: Sendable, Equatable {
	package let min: Double
	package let max: Double
	package let mean: Double

	fileprivate init?(of values: [Double?]) {
		var min = Double.infinity
		var max = -Double.infinity
		var sum = 0.0
		var count = 0
		for case let value? in values where value.isFinite {
			if value < min { min = value }
			if value > max { max = value }
			sum += value
			count += 1
		}
		guard count > 0 else { return nil }
		self.min = min
		self.max = max
		self.mean = OneDecimal.round(sum / Double(count))
	}
}

package struct StreamSummary: Sendable, Equatable {
	package let sampleCount: Int
	package let channels: [String: ChannelSummary]
	package let unanswered: [String]
	package let unknown: [String]
	package let unread: [String]

	package init(
		summarizing samples: [StreamSamples], asked: StreamChannels,
		unknown: Set<String> = [], unread: Set<String> = []
	) {
		var channels: [String: ChannelSummary] = [:]
		var sampleCount = 0
		for stream in samples where asked.names.contains(stream.channel) {
			guard let summary = ChannelSummary(of: stream.values) else { continue }
			channels[stream.channel] = summary
			sampleCount = Swift.max(sampleCount, stream.values.count)
		}
		var seen: Set<String> = []
		let missing = asked.names.filter { channels[$0] == nil && seen.insert($0).inserted }
		self.sampleCount = sampleCount
		self.channels = channels
		self.unknown = missing.filter(unknown.contains)
		self.unread = missing.filter(unread.contains)
		self.unanswered = missing.filter { !unknown.contains($0) && !unread.contains($0) }
	}
}
