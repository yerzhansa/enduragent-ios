import EnduragentCoach

extension AthleteProfile {
	package static func cyclist(id: String = "i1001", name: String, ftp: Double) -> AthleteProfile {
		AthleteProfile(id: id, name: name, ftp: FTPReading(.number(ftp)), readings: Readings([:]))
	}

	package func with(ftp: FTPReading) -> AthleteProfile {
		rebuilt(ftp: ftp)
	}

	package func with(
		_ readings: [ProfileField: Double], sex: String? = nil, ageYears: Int? = nil,
		settingsSports: [String] = [], powerZones: [TrainingZone] = [],
		heartRateZones: [TrainingZone] = []
	) -> AthleteProfile {
		AthleteProfile(
			id: id, name: name, ftp: ftp, readings: Readings(readings), sex: sex,
			ageYears: ageYears, settingsSports: settingsSports, powerZones: powerZones,
			heartRateZones: heartRateZones)
	}

	fileprivate func named(_ name: String) -> AthleteProfile {
		rebuilt(name: name)
	}

	private func rebuilt(name: String? = nil, ftp: FTPReading? = nil) -> AthleteProfile {
		AthleteProfile(
			id: id, name: name ?? self.name, ftp: ftp ?? self.ftp, readings: readings, sex: sex,
			ageYears: ageYears, settingsSports: settingsSports, powerZones: powerZones,
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

extension FakeIntervalsClient {
	public static func firstWeek(today: CivilDate) -> FakeIntervalsClient {
		let intervals = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250)
		intervals.wellness = [.on(today, [.fitness: 42, .fatigue: 49])]
		intervals.activities = [
			.ride(
				name: "Tuesday sweet spot", date: today.adding(days: -6).rawValue,
				durationS: 3_600, trainingLoad: 72),
			.ride(
				name: "Saturday group ride", date: today.adding(days: -2).rawValue,
				durationS: 7_800, trainingLoad: 118),
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
