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

	package init(profile: AthleteProfile?, wellness: [WellnessDay]?, lookback: ReadRange) {
		self =
			SnapshotLines(
				profile: profile.flatMap(ProfileLine.init),
				wellness: wellness.flatMap { WellnessLine(latestOf: $0, in: lookback) }
			).map(Self.available) ?? .unavailable(.nothingUsable)
	}
}

package enum SnapshotGap: Sendable, Equatable {
	case nothingUsable
	case deadlineMissed
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

	var text: String {
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
			guard let value = shown[field], let label = field.label else { continue }
			parts.append(
				[label, SnapshotNumber.text(value), field.unit].compactMap { $0 }.joined(
					separator: " "))
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
	private let deadlineSleep: @Sendable (Duration) async throws(CancellationError) -> Void
	private let diagnostics: DiagnosticsLog

	package init(
		clock: any Clock,
		deadlineSleep: @escaping @Sendable (Duration) async throws(CancellationError) -> Void,
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
		var profile: Result<AthleteProfile, any Error>?
		var wellness: Result<[WellnessDay], any Error>?
		let stopped = await withTaskGroup(of: Arrival.self) { group in
			group.addTask { await Self.arrival(Arrival.profile) { try await client.profile() } }
			group.addTask {
				await Self.arrival(Arrival.wellness) { try await client.wellness(in: lookback) }
			}
			group.addTask { [deadlineSleep] in
				do {
					try await deadlineSleep(SnapshotPolicy.deadline)
				} catch {
					return .stopped
				}
				return .deadline
			}
			defer { group.cancelAll() }
			for await arrival in group {
				switch arrival {
				case .profile(let read): profile = read
				case .wellness(let read): wellness = read
				case .deadline: return false
				case .stopped: return true
				}
				if profile != nil, wellness != nil { return false }
			}
			return false
		}
		if stopped || Task.isCancelled { throw CancellationError() }
		if case .failure(let error)? = profile {
			diagnostics.record(.snapshotReadFailed(attempt, .profile, TrainingFailure(error)))
		}
		if case .failure(let error)? = wellness {
			diagnostics.record(.snapshotReadFailed(attempt, .wellness, TrainingFailure(error)))
		}
		guard let profile, let wellness else {
			diagnostics.record(.snapshotDeadlineMissed(attempt))
			return .unavailable(.deadlineMissed)
		}
		return TrainingSnapshot(
			profile: profile.success, wellness: wellness.success, lookback: lookback)
	}

	private static func arrival<Value: Sendable>(
		_ arrived: (Result<Value, any Error>) -> Arrival,
		reading read: () async throws -> Value
	) async -> Arrival {
		do {
			return arrived(.success(try await read()))
		} catch is CancellationError {
			return .stopped
		} catch {
			return arrived(.failure(error))
		}
	}
}

private enum Arrival: Sendable {
	case profile(Result<AthleteProfile, any Error>)
	case wellness(Result<[WellnessDay], any Error>)
	case deadline
	case stopped
}

extension Result {
	fileprivate var success: Success? {
		if case .success(let value) = self { value } else { nil }
	}
}

extension ProfileField {
	fileprivate func isShown(_ value: Double) -> Bool {
		switch self {
		case .lthr, .maxHeartRate: true
		case .restingHeartRate: SnapshotPolicy.restingHeartRate.contains(value)
		case .weight: SnapshotPolicy.weightKilograms.contains(value)
		case .indoorFTP, .wPrime, .maxPower, .sweetSpotMin, .sweetSpotMax: false
		}
	}

	fileprivate var label: String? {
		switch self {
		case .lthr: "LTHR"
		case .maxHeartRate: "max HR"
		case .restingHeartRate: "resting HR"
		case .weight: "weight"
		case .indoorFTP, .wPrime, .maxPower, .sweetSpotMin, .sweetSpotMax: nil
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
		let tenths = OneDecimal.round(value.magnitude)
		return String(format: "%.1f", value < 0 ? -tenths : tenths)
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
