import Foundation

package enum SnapshotPolicy {
	package static let deadline: Duration = .seconds(5)
	package static let weightKilograms = 30.0...200.0
	package static let restingHeartRate = 30.0...220.0
}

package enum TrainingSnapshot: Sendable, Equatable {
	case notConnected
	case unavailable(SnapshotGap)
	case available(SnapshotLines)

	package init(
		profile: SnapshotRead<AthleteProfile>,
		wellness: SnapshotRead<[WellnessDay]>,
		lookback: ReadRange
	) {
		var profileLine: ProfileLine?
		if case .read(let athlete) = profile { profileLine = ProfileLine(athlete) }
		var wellnessLine: WellnessLine?
		if case .read(let days) = wellness {
			wellnessLine = WellnessLine(latestOf: days, in: lookback)
		}
		self =
			SnapshotLines(profile: profileLine, wellness: wellnessLine).map(Self.available)
			?? .unavailable(.nothingUsable)
	}

	package var promptSection: String {
		switch self {
		case .notConnected:
			return PromptStaticBlocks.snapshotNotConnected
		case .unavailable:
			return PromptStaticBlocks.snapshotFallback
		case .available(let lines):
			var section =
				PromptStaticBlocks.snapshotHeading + "\n\n" + lines.text + "\n"
				+ PromptStaticBlocks.snapshotGuidance
			if case .implausible? = lines.profile?.ftp {
				section += "\n" + PromptStaticBlocks.snapshotQualitativeFTP
			}
			return section
		}
	}
}

package enum SnapshotGap: Sendable, Equatable {
	case nothingUsable
	case deadlineMissed
}

package enum SnapshotRead<Value: Sendable>: Sendable {
	case read(Value)
	case failed(TrainingFailure)
}

package enum SnapshotLineKind: Sendable, Equatable {
	case profile
	case wellness
}

package struct SnapshotLines: Sendable, Equatable {
	package let profile: ProfileLine?
	package let wellness: WellnessLine?

	package init?(profile: ProfileLine?, wellness: WellnessLine?) {
		guard profile != nil || wellness != nil else { return nil }
		self.profile = profile
		self.wellness = wellness
	}

	fileprivate var text: String {
		[profile?.text, wellness?.text].compactMap { $0 }.joined(separator: "\n")
	}
}

package struct ProfileLine: Sendable, Equatable {
	package let ftp: FTPReading
	package let shown: Readings<ProfileField>

	package init?(_ profile: AthleteProfile) {
		let shown = profile.readings.keeping { field, value in field.isShown(value) }
		guard profile.ftp != .absent || !shown.isEmpty else { return nil }
		self.ftp = profile.ftp
		self.shown = shown
	}

	package var text: String {
		var parts: [String] = []
		switch ftp {
		case .absent:
			break
		case .usable(let watts):
			parts.append("FTP \(SnapshotNumber.text(watts.value)) W")
		case .implausible(let reported?):
			parts.append("FTP \(SnapshotNumber.text(reported)) W (not usable)")
		case .implausible(nil):
			parts.append("FTP not usable")
		}
		for field in ProfileField.allCases {
			guard let value = shown[field] else { continue }
			parts.append("\(field.label) \(SnapshotNumber.text(value)) \(field.unit)")
		}
		return "Profile: " + parts.joined(separator: SnapshotNumber.separator)
	}
}

package struct WellnessLine: Sendable, Equatable {
	package let date: CivilDate
	package let shown: Readings<WellnessField>

	package init?(latestOf days: [WellnessDay], in lookback: ReadRange) {
		var latest: (date: CivilDate, shown: Readings<WellnessField>)?
		for day in days where lookback.contains(day.date) {
			if let latest, day.date < latest.date { continue }
			let shown = day.readings.keeping { field, value in field.isShown(value) }
			if !shown.isEmpty { latest = (day.date, shown) }
		}
		guard let latest else { return nil }
		self.date = latest.date
		self.shown = latest.shown
	}

	package var text: String {
		var parts: [String] = []
		func add(_ field: WellnessField, _ label: String, unit: String = "") {
			guard let value = shown[field] else { return }
			parts.append("\(label) \(SnapshotNumber.text(value))\(unit)")
		}
		add(.fitness, "Fitness")
		add(.fatigue, "Fatigue")
		if let form = WellnessDay(date: date, readings: shown).form {
			parts.append("Form \(SnapshotNumber.signed(OneDecimal.round(form)))")
		}
		add(.restingHeartRate, "resting HR", unit: " bpm")
		add(.hrv, "HRV")
		if let seconds = shown[.sleepSeconds] {
			parts.append("sleep \(SnapshotNumber.sleep(seconds))")
		}
		add(.sleepScore, "sleep score")
		add(.sleepQuality, "sleep quality")
		add(.weight, "weight", unit: " kg")
		add(.readiness, "readiness")
		add(.reportedFatigue, "reported fatigue")
		add(.soreness, "soreness")
		add(.stress, "stress")
		add(.mood, "mood")
		add(.motivation, "motivation")
		add(.injury, "injury")
		return "Wellness \(date.rawValue): " + parts.joined(separator: SnapshotNumber.separator)
	}
}

package struct TrainingSnapshotReader: Sendable {
	private let clock: any Clock
	private let deadlineSleep: @Sendable (Duration) async throws -> Void
	private let diagnostics: DiagnosticsLog

	package init(
		clock: any Clock,
		deadlineSleep: @escaping @Sendable (Duration) async throws -> Void,
		diagnostics: DiagnosticsLog
	) {
		self.clock = clock
		self.deadlineSleep = deadlineSleep
		self.diagnostics = diagnostics
	}

	package func snapshot(for training: TrainingConnection, attempt: AttemptID)
		async throws(CancellationError) -> TrainingSnapshot
	{
		guard case .connected(let connected) = training else { return .notConnected }
		let lookback = ReadRange.snapshotLookback(
			endingOn: IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone))
		let client = connected.client
		let race = await withTaskGroup(of: SnapshotArrival.self) { group in
			group.addTask { .profile(await Self.outcome { try await client.profile() }) }
			group.addTask {
				.wellness(await Self.outcome { try await client.wellness(in: lookback) })
			}
			group.addTask { [deadlineSleep] in
				do {
					try await deadlineSleep(SnapshotPolicy.deadline)
				} catch is CancellationError {
					return .deadlineAbandoned
				} catch {
					fatalError("Snapshot deadline sleep failed: \(error)")
				}
				return .deadlinePassed
			}
			var race = SnapshotRace()
			for await arrival in group {
				race.take(arrival)
				if race.isDecided { break }
			}
			group.cancelAll()
			return race
		}
		return try settle(race, lookback: lookback, attempt: attempt)
	}

	private func settle(_ race: SnapshotRace, lookback: ReadRange, attempt: AttemptID)
		throws(CancellationError) -> TrainingSnapshot
	{
		if race.stopped || Task.isCancelled { throw CancellationError() }
		if case .failed(let failure)? = race.profile {
			diagnostics.record(.snapshotReadFailed(attempt, .profile, failure))
		}
		if case .failed(let failure)? = race.wellness {
			diagnostics.record(.snapshotReadFailed(attempt, .wellness, failure))
		}
		guard let profile = race.profile, let wellness = race.wellness else {
			diagnostics.record(.snapshotDeadlineMissed(attempt))
			return .unavailable(.deadlineMissed)
		}
		return TrainingSnapshot(profile: profile, wellness: wellness, lookback: lookback)
	}

	private static func outcome<Value: Sendable>(
		of read: @Sendable () async throws -> Value
	) async -> SnapshotOutcome<Value> {
		do {
			return .finished(.read(try await read()))
		} catch is CancellationError {
			return .stopped
		} catch {
			return Task.isCancelled ? .stopped : .finished(.failed(TrainingFailure(error)))
		}
	}
}

private enum SnapshotOutcome<Value: Sendable>: Sendable {
	case finished(SnapshotRead<Value>)
	case stopped
}

private enum SnapshotArrival: Sendable {
	case profile(SnapshotOutcome<AthleteProfile>)
	case wellness(SnapshotOutcome<[WellnessDay]>)
	case deadlinePassed
	case deadlineAbandoned
}

private struct SnapshotRace: Sendable {
	var profile: SnapshotRead<AthleteProfile>?
	var wellness: SnapshotRead<[WellnessDay]>?
	var stopped = false
	var deadlinePassed = false

	var isDecided: Bool {
		stopped || deadlinePassed || (profile != nil && wellness != nil)
	}

	mutating func take(_ arrival: SnapshotArrival) {
		switch arrival {
		case .profile(.finished(let read)): profile = read
		case .wellness(.finished(let read)): wellness = read
		case .profile(.stopped), .wellness(.stopped), .deadlineAbandoned: stopped = true
		case .deadlinePassed: deadlinePassed = true
		}
	}
}

extension ProfileField {
	fileprivate func isShown(_ value: Double) -> Bool {
		switch self {
		case .lthr, .maxHeartRate: true
		case .restingHeartRate: SnapshotPolicy.restingHeartRate.contains(value)
		case .weight: SnapshotPolicy.weightKilograms.contains(value)
		}
	}

	fileprivate var label: String {
		switch self {
		case .lthr: "LTHR"
		case .maxHeartRate: "max HR"
		case .restingHeartRate: "resting HR"
		case .weight: "weight"
		}
	}

	fileprivate var unit: String {
		switch self {
		case .lthr, .maxHeartRate, .restingHeartRate: "bpm"
		case .weight: "kg"
		}
	}
}

extension WellnessField {
	fileprivate func isShown(_ value: Double) -> Bool {
		switch self {
		case .rampRate:
			false
		case .restingHeartRate:
			SnapshotPolicy.restingHeartRate.contains(value)
		case .weight:
			SnapshotPolicy.weightKilograms.contains(value)
		case .fitness, .fatigue, .hrv, .sleepSeconds, .sleepScore, .sleepQuality, .readiness,
			.soreness, .stress, .mood, .motivation, .injury, .reportedFatigue:
			true
		}
	}
}

private enum SnapshotNumber {
	static let separator = " · "

	static func text(_ value: Double) -> String {
		if value == value.rounded(.towardZero) {
			return String(format: "%.0f", value == 0 ? 0 : value)
		}
		let quarters = value * 4
		guard quarters == quarters.rounded(.towardZero) else {
			return String(format: "%.1f", value)
		}
		let tenths = (abs(value) * 10 + 0.5).rounded(.down)
		return String(format: "%.1f", (value < 0 ? -tenths : tenths) / 10)
	}

	static func signed(_ value: Double) -> String {
		value > 0 ? "+" + text(value) : text(value)
	}

	static func sleep(_ seconds: Double) -> String {
		let minutes = (seconds / 60 + 0.5).rounded(.down)
		let hours = (minutes / 60).rounded(.down)
		let rest = String(format: "%.0f", minutes.truncatingRemainder(dividingBy: 60))
		return String(format: "%.0f", hours) + "h" + (rest.count < 2 ? "0" + rest : rest)
	}
}
