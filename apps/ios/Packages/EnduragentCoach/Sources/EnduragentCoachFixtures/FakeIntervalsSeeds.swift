import EnduragentCoach

extension AthleteProfile {
	package static func cyclist(id: String = "i1001", name: String, ftp: Double) -> AthleteProfile {
		AthleteProfile(id: id, name: name, ftp: FTPReading(.number(ftp)), readings: Readings([:]))
	}

	package func with(ftp: FTPReading) -> AthleteProfile {
		rebuilt(ftp: ftp)
	}

	package func with(
		_ readings: [ProfileField: Double], sex: String? = nil, dateOfBirth: CivilDate? = nil,
		settingsSports: [String] = [], powerZones: [TrainingZone] = [],
		heartRateZones: [TrainingZone] = []
	) -> AthleteProfile {
		AthleteProfile(
			id: id, name: name, ftp: ftp, readings: Readings(readings), sex: sex,
			dateOfBirth: dateOfBirth, settingsSports: settingsSports, powerZones: powerZones,
			heartRateZones: heartRateZones)
	}

	fileprivate func named(_ name: String) -> AthleteProfile {
		rebuilt(name: name)
	}

	private func rebuilt(name: String? = nil, ftp: FTPReading? = nil) -> AthleteProfile {
		AthleteProfile(
			id: id, name: name ?? self.name, ftp: ftp ?? self.ftp, readings: readings, sex: sex,
			dateOfBirth: dateOfBirth, settingsSports: settingsSports, powerZones: powerZones,
			heartRateZones: heartRateZones)
	}
}

extension WellnessDay {
	package static func on(_ date: CivilDate, _ readings: [WellnessField: Double] = [:])
		-> WellnessDay
	{
		WellnessDay(date: date, readings: Readings(readings))
	}
}

extension Activity {
	package static func recorded(
		_ id: String, _ name: String?, sport: String? = "Ride", on date: CivilDate,
		at secondOfDay: Int? = nil, ftp: Double? = nil, _ readings: [ActivityField: Double] = [:]
	) -> Activity {
		guard let id = ActivityID(rawValue: id) else {
			fatalError("\(id) is not an activity identifier")
		}
		guard let start = LocalStart(date: date, secondOfDay: secondOfDay) else {
			fatalError("\(String(describing: secondOfDay)) is not a second of the day")
		}
		return Activity(
			id: id, name: name, sport: sport, start: start, readings: Readings(readings), ftp: ftp)
	}
}

extension FakeIntervalsClient {
	public static func firstWeek(today: CivilDate) -> FakeIntervalsClient {
		let intervals = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250)
		intervals.wellness = [.on(today, [.fitness: 42, .fatigue: 49])]
		intervals.activities = [
			.recorded(
				"i5501", "Tuesday sweet spot", on: today.adding(days: -6), at: 18 * 3_600,
				[.duration: 3_600, .load: 72]),
			.recorded(
				"i5502", "Saturday group ride", on: today.adding(days: -2), at: 9 * 3_600,
				[.duration: 7_800, .load: 118]),
		]
		return intervals
	}

	public convenience init(athleteName: String, ftp: Double) {
		self.init(athlete: .cyclist(name: athleteName, ftp: ftp))
	}

	public func rename(athleteTo name: String) {
		athlete = athlete.named(name)
	}

	public func seedWellness(_ rows: [(date: CivilDate, fitness: Double?, fatigue: Double?)]) {
		wellness = rows.map { row in
			var readings: [WellnessField: Double] = [:]
			readings[.fitness] = row.fitness
			readings[.fatigue] = row.fatigue
			return .on(row.date, readings)
		}
	}
}
