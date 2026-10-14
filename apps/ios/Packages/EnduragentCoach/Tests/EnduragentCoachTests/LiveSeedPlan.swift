import Foundation

@testable import EnduragentCoach

struct SeedRandom {
	private var state: UInt64

	init(key: String) {
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325
		for byte in key.utf8 {
			hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
		}
		state = hash
	}

	mutating func next() -> UInt64 {
		state &+= 0x9e37_79b9_7f4a_7c15
		var mixed = state
		mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
		mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
		return mixed ^ (mixed >> 31)
	}

	mutating func unit() -> Double {
		Double(next() >> 11) / Double(UInt64(1) << 53)
	}

	mutating func noise(_ spread: Double) -> Double {
		(unit() + unit() - 1) * spread
	}

	mutating func step(of size: Int, count: Int) -> Int {
		size * Int(unit() * Double(count))
	}
}

enum SeedSport: String, Sendable {
	case ride = "Biking"
	case run = "Running"
}

struct SeedBlock: Sendable, Equatable {
	let seconds: Int
	let from: Double
	let to: Double

	init(minutes: Int, _ from: Double, _ to: Double? = nil) {
		self.seconds = minutes * 60
		self.from = from
		self.to = to ?? from
	}

	func effort(at second: Int) -> Double {
		from + (to - from) * Double(second) / Double(max(seconds - 1, 1))
	}
}

struct SeedStart: Sendable, Equatable {
	let date: CivilDate
	let secondOfDay: Int

	init(_ date: CivilDate, _ hour: Int, _ minute: Int) {
		self.date = date
		self.secondOfDay = hour * 3_600 + minute * 60
	}

	func instant(in timeZone: TimeZone) throws -> Date {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = timeZone
		let parts = date.rawValue.split(separator: "-").compactMap { Int($0) }
		guard parts.count == 3,
			let instant = calendar.date(
				from: DateComponents(
					year: parts[0], month: parts[1], day: parts[2], hour: secondOfDay / 3_600,
					minute: secondOfDay / 60 % 60))
		else {
			throw LiveCheckStop(
				description: "\(date.rawValue) has no start in \(timeZone.identifier)")
		}
		return instant
	}
}

struct SeedActivity: Sendable, Equatable {
	let key: String
	let title: String
	let sport: SeedSport
	let start: SeedStart
	let blocks: [SeedBlock]
	var recordsPower = true
	var feel: Int?
	var rpe: Int?

	var externalID: String { LiveSeedPlan.externalIDPrefix + key }
	var name: String { "\(LiveSeedPlan.namePrefix) \(title)" }
	var seconds: Int { blocks.map(\.seconds).reduce(0, +) }
	var endSecondOfDay: Int { start.secondOfDay + seconds }
}

struct SeedWellnessDay: Sendable, Equatable {
	static let fields = ["hrv", "restingHR", "sleepSecs", "weight"]

	let date: CivilDate
	let values: [String: Double]

	func matches(_ current: [String: Double]) -> Bool {
		Self.fields.allSatisfy { holds(current, at: $0) }
	}

	func holds(_ current: [String: Double], at field: String) -> Bool {
		guard let mine = values[field], let theirs = current[field] else { return false }
		return abs(mine - theirs) < 0.05
	}
}

struct LiveSeedPlan: Sendable {
	static let externalIDPrefix = "enduragent-seed-"
	static let namePrefix = "[synthetic]"
	static let days = 42

	let anchor: CivilDate
	let activities: [SeedActivity]
	let wellness: [SeedWellnessDay]

	var oldest: CivilDate { anchor.adding(days: -(Self.days - 1)) }

	init(anchor: CivilDate) {
		self.anchor = anchor
		let oldest = anchor.adding(days: -(Self.days - 1))
		self.activities = Self.baseRides(from: oldest) + Self.lastWeek(before: anchor)
		self.wellness = (0..<Self.days).map { Self.wellnessDay(oldest.adding(days: $0), index: $0) }
	}

	private static func baseRides(from oldest: CivilDate) -> [SeedActivity] {
		let slots = [(0, 6, 30), (2, 6, 30), (4, 17, 45), (5, 8, 0)]
		var rides: [SeedActivity] = []
		for week in 0..<5 {
			for (slot, (weekday, hour, minute)) in slots.enumerated() {
				let number = week * slots.count + slot + 1
				let key = String(format: "base-%02d", number)
				var random = SeedRandom(key: key)
				let long = slot == slots.count - 1
				let minutes =
					long ? 90 + random.step(of: 5, count: 7) : 45 + random.step(of: 5, count: 10)
				let endurance = 0.64 + 0.08 * random.unit()
				let tempo = number % 3 == 1 && minutes >= 75
				rides.append(
					SeedActivity(
						key: key, title: tempo ? "Endurance with tempo" : "Endurance",
						sport: .ride,
						start: SeedStart(oldest.adding(days: week * 7 + weekday), hour, minute),
						blocks: baseBlocks(minutes: minutes, endurance: endurance, tempo: tempo)))
			}
		}
		return rides
	}

	private static func baseBlocks(minutes: Int, endurance: Double, tempo: Bool) -> [SeedBlock] {
		let warmUp = SeedBlock(minutes: 10, 0.5, endurance)
		let coolDown = SeedBlock(minutes: 8, endurance - 0.04, 0.45)
		guard tempo else {
			return [warmUp, SeedBlock(minutes: minutes - 18, endurance), coolDown]
		}
		let steady = (minutes - 48) / 2
		return [
			warmUp, SeedBlock(minutes: steady, endurance), SeedBlock(minutes: 12, 0.85),
			SeedBlock(minutes: 6, endurance), SeedBlock(minutes: 12, 0.87),
			SeedBlock(minutes: minutes - 48 - steady, endurance), coolDown,
		]
	}

	private static func lastWeek(before anchor: CivilDate) -> [SeedActivity] {
		[
			SeedActivity(
				key: "heart-rate-only", title: "Easy spin without a power meter", sport: .ride,
				start: SeedStart(anchor.adding(days: -6), 6, 45),
				blocks: [
					SeedBlock(minutes: 10, 0.5, 0.62), SeedBlock(minutes: 40, 0.63),
					SeedBlock(minutes: 5, 0.58, 0.45),
				], recordsPower: false, feel: 2, rpe: 3),
			SeedActivity(
				key: "second-ride", title: "Endurance", sport: .ride,
				start: SeedStart(anchor.adding(days: -5), 7, 0),
				blocks: [
					SeedBlock(minutes: 10, 0.5, 0.68), SeedBlock(minutes: 57, 0.68),
					SeedBlock(minutes: 8, 0.64, 0.45),
				], feel: 1, rpe: 4),
			SeedActivity(
				key: "openers-ride", title: "Openers before a run", sport: .ride,
				start: SeedStart(anchor.adding(days: -4), 8, 0),
				blocks: [
					SeedBlock(minutes: 5, 0.5, 0.65), SeedBlock(minutes: 6, 0.72),
					SeedBlock(minutes: 2, 1.02), SeedBlock(minutes: 2, 0.5),
				], feel: 2, rpe: 5),
			SeedActivity(
				key: "run-off-the-bike", title: "Run off the bike", sport: .run,
				start: SeedStart(anchor.adding(days: -4), 8, 25),
				blocks: [
					SeedBlock(minutes: 5, 0.65, 0.75), SeedBlock(minutes: 20, 0.78),
					SeedBlock(minutes: 5, 0.7, 0.6),
				], recordsPower: false, feel: 3, rpe: 6),
			SeedActivity(
				key: "threshold", title: "Threshold 3 × 10 min", sport: .ride,
				start: SeedStart(anchor.adding(days: -2), 17, 30),
				blocks: [
					SeedBlock(minutes: 15, 0.5, 0.75), SeedBlock(minutes: 10, 0.98),
					SeedBlock(minutes: 5, 0.5), SeedBlock(minutes: 10, 0.99),
					SeedBlock(minutes: 5, 0.5), SeedBlock(minutes: 10, 1.0),
					SeedBlock(minutes: 10, 0.6, 0.45),
				], feel: 4, rpe: 8),
		]
	}

	private static func wellnessDay(_ date: CivilDate, index: Int) -> SeedWellnessDay {
		var random = SeedRandom(key: "wellness-\(index)")
		let hrv = 60 + 5 * sin(Double(index) / 6) + random.noise(4) - (index == days - 2 ? 8 : 0)
		let restingHR = 48 + random.noise(2.5)
		let sleepMinutes = 435 + random.noise(40)
		let weight = 72.6 - 0.012 * Double(index) + random.noise(0.3)
		return SeedWellnessDay(
			date: date,
			values: [
				"hrv": (hrv * 10).rounded() / 10,
				"restingHR": restingHR.rounded(),
				"sleepSecs": sleepMinutes.rounded() * 60,
				"weight": (weight * 10).rounded() / 10,
			])
	}
}
