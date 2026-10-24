struct SampleWeekRequest: Sendable, Equatable {
	let tier: VolumeTier
	let scheduleType: ScheduleType
	let availableDays: [Weekday]?
	let keySessionDay: Weekday?
	let sessionsPerWeek: Int?
}

struct SampleSession: Sendable, Equatable {
	enum Kind: String, Sendable {
		case endurance
		case sweetSpot = "sweet_spot"
		case threshold, long, recovery
	}

	let day: String?
	let name: String
	let duration: String
	let kind: Kind
	let spacing: String?

	var json: JSONValue {
		var fields: [String: JSONValue] = [
			"name": .string(name),
			"duration": .string(duration),
			"type": .string(kind.rawValue),
		]
		fields["day"] = day.map(JSONValue.string)
		fields["spacing"] = spacing.map(JSONValue.string)
		return .object(fields)
	}
}

struct SampleWeek: Sendable, Equatable {
	let sessions: [SampleSession]

	var json: JSONValue {
		.array(sessions.map(\.json))
	}
}

extension Planning {
	static func sampleWeek(_ request: SampleWeekRequest) -> SampleWeek {
		let templates = SessionTemplate.week(request.tier)
		if request.scheduleType == .fixed, let days = request.availableDays, !days.isEmpty {
			return SampleWeek(
				sessions: placeFixed(templates, on: days, keySessionDay: request.keySessionDay))
		}
		return SampleWeek(sessions: flexibleStack(templates, limit: request.sessionsPerWeek))
	}

	private static func placeFixed(
		_ templates: [SessionTemplate], on days: [Weekday], keySessionDay: Weekday?
	) -> [SampleSession] {
		let sortedDays = days.sorted { $0.order < $1.order }
		var toPlace = Array(templates.sorted { $0.priority < $1.priority }.prefix(sortedDays.count))
		let longSession = toPlace.firstIndex { $0.kind == .long }.map { toPlace.remove(at: $0) }
		var assignments: [Weekday: SessionTemplate] = [:]
		let keyDay = keySessionDay.flatMap { sortedDays.contains($0) ? $0 : nil }
		if let longSession, let longDay = keyDay ?? sortedDays.last {
			assignments[longDay] = longSession
		}
		var remaining = sortedDays.filter { assignments[$0] == nil }
		for session in toPlace where session.isHard {
			guard !remaining.isEmpty else { break }
			let hardDays = assignments.filter { $0.value.isHard || $0.value.kind == .long }
				.map(\.key.order)
			var best = remaining.startIndex
			var bestDistance = -1
			for index in remaining.indices {
				let distance = hardDays.map { remaining[index].distance(to: $0) }.min() ?? 7
				if distance > bestDistance {
					bestDistance = distance
					best = index
				}
			}
			assignments[remaining.remove(at: best)] = session
		}
		for session in toPlace where !session.isHard {
			guard !remaining.isEmpty else { break }
			assignments[remaining.removeFirst()] = session
		}
		return sortedDays.compactMap { day in
			assignments[day].map { $0.session(day: day.label, spacing: nil) }
		}
	}

	private static func flexibleStack(_ templates: [SessionTemplate], limit: Int?)
		-> [SampleSession]
	{
		let sorted = templates.sorted { $0.priority < $1.priority }
		let hard = sorted.filter(\.isHard)
		let easy = sorted.filter { !$0.isHard && $0.kind != .long && $0.kind != .recovery }
		var ordered: [SessionTemplate] = []
		for index in 0..<max(easy.count, hard.count) {
			if index < easy.count { ordered.append(easy[index]) }
			if index < hard.count { ordered.append(hard[index]) }
		}
		ordered += sorted.filter { $0.kind == .long }.prefix(1)
		ordered += sorted.filter { $0.kind == .recovery }
		let limited = if let limit, limit > 0 { Array(ordered.prefix(limit)) } else { ordered }
		return limited.indices.map { index in
			let session = limited[index]
			let spacing: String? =
				if session.kind == .long && index > 0 {
					"Rest day before this session"
				} else if session.isHard && index > 0 && limited[index - 1].isHard {
					"Easy day or rest before this"
				} else {
					nil
				}
			return session.session(day: nil, spacing: spacing)
		}
	}
}

private struct SessionTemplate {
	let name: String
	let duration: String
	let kind: SampleSession.Kind
	let priority: Int
	let isHard: Bool

	func session(day: String?, spacing: String?) -> SampleSession {
		SampleSession(
			day: day, name: "\(name) \(duration)", duration: duration, kind: kind, spacing: spacing)
	}

	static func week(_ tier: VolumeTier) -> [SessionTemplate] {
		switch tier {
		case .low:
			[
				SessionTemplate(
					"Endurance Ride Z2", "45min", .endurance, priority: 2, isHard: false),
				SessionTemplate("Sweet Spot", "60min", .sweetSpot, priority: 1, isHard: true),
				SessionTemplate("Long Ride", "1.5h", .long, priority: 0, isHard: false),
			]
		case .medium:
			[
				SessionTemplate(
					"Endurance Ride Z2", "60min", .endurance, priority: 2, isHard: false),
				SessionTemplate("Sweet Spot", "75min", .sweetSpot, priority: 1, isHard: true),
				SessionTemplate("Long Ride", "2.5h", .long, priority: 0, isHard: false),
				SessionTemplate("Recovery Spin", "45min", .recovery, priority: 3, isHard: false),
			]
		case .high:
			[
				SessionTemplate(
					"Endurance Ride Z2", "60min", .endurance, priority: 3, isHard: false),
				SessionTemplate(
					"Threshold Intervals", "75min", .threshold, priority: 1, isHard: true),
				SessionTemplate(
					"Endurance Ride Z2", "50min", .endurance, priority: 4, isHard: false),
				SessionTemplate("Sweet Spot", "75min", .sweetSpot, priority: 2, isHard: true),
				SessionTemplate("Long Ride", "3h", .long, priority: 0, isHard: false),
				SessionTemplate("Recovery Spin", "45min", .recovery, priority: 5, isHard: false),
			]
		}
	}

	private init(
		_ name: String, _ duration: String, _ kind: SampleSession.Kind, priority: Int,
		isHard: Bool
	) {
		self.name = name
		self.duration = duration
		self.kind = kind
		self.priority = priority
		self.isHard = isHard
	}
}

extension Weekday {
	fileprivate var order: Int {
		switch self {
		case .mon: 0
		case .tue: 1
		case .wed: 2
		case .thu: 3
		case .fri: 4
		case .sat: 5
		case .sun: 6
		}
	}

	fileprivate var label: String {
		rawValue.prefix(1).uppercased() + rawValue.dropFirst()
	}

	fileprivate func distance(to order: Int) -> Int {
		let apart = abs(self.order - order)
		return min(apart, 7 - apart)
	}
}
