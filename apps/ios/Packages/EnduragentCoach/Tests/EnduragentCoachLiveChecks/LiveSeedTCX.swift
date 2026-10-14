import Foundation

@testable import EnduragentCoach

struct SeedAthlete: Sendable, Equatable {
	static let thresholdRunSpeed = 4.2

	let ftp: Double
	let lthr: Double
	let maxHeartRate: Double

	init(ftp: Double, lthr: Double, maxHeartRate: Double) {
		self.ftp = ftp
		self.lthr = lthr
		self.maxHeartRate = maxHeartRate
	}

	init(_ profile: AthleteProfile) throws {
		guard case .usable(let ftp) = profile.ftp, let lthr = profile.readings[.lthr],
			let maxHeartRate = profile.readings[.maxHeartRate]
		else {
			throw LiveCheckStop(
				description:
					"The profile needs a usable FTP, a threshold heart rate and a max heart rate before seeding; set them on intervals.icu."
			)
		}
		self.init(ftp: ftp.value, lthr: lthr, maxHeartRate: maxHeartRate)
	}
}

struct SeedSample: Sendable, Equatable {
	let watts: Int?
	let heartRate: Int
	let cadence: Int?
	let speed: Double
	let distance: Double
}

enum LiveSeedTCX {
	static func laps(of activity: SeedActivity, athlete: SeedAthlete) -> [[SeedSample]] {
		var random = SeedRandom(key: "\(activity.key)-samples")
		var drift = 0.0
		var heart = 88.0
		var distance = 0.0
		var elapsed = 0
		return activity.blocks.map { block in
			(0..<block.seconds).map { second in
				let planned = block.effort(at: second)
				drift = 0.95 * drift + random.noise(0.035)
				let effort = max(0, planned * (1 + drift + random.noise(0.03)))
				let target = min(
					70 + (athlete.lthr - 70) * planned + 3 * Double(elapsed) / 3_600,
					athlete.maxHeartRate - 3)
				heart += (target - heart) / 30 + random.noise(0.8)
				elapsed += 1
				let watts = athlete.ftp * effort
				let speed: Double
				let cadence: Int?
				switch activity.sport {
				case .ride:
					speed = rideSpeed(watts: watts)
					cadence = Int((86 + 6 * planned + random.noise(3)).rounded())
				case .run:
					speed = SeedAthlete.thresholdRunSpeed * effort
					cadence = nil
				}
				distance += speed
				return SeedSample(
					watts: activity.recordsPower ? Int(watts.rounded()) : nil,
					heartRate: Int(heart.rounded()), cadence: cadence, speed: speed,
					distance: distance)
			}
		}
	}

	static func document(of activity: SeedActivity, athlete: SeedAthlete, timeZone: TimeZone)
		throws -> String
	{
		let start = try activity.start.instant(in: timeZone)
		var lines = [
			#"<?xml version="1.0" encoding="UTF-8"?>"#,
			#"<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2">"#,
			"<Activities>", #"<Activity Sport="\#(activity.sport.rawValue)">"#,
			"<Id>\(stamp(start))</Id>",
		]
		var offset = 0
		var lapStartDistance = 0.0
		for samples in laps(of: activity, athlete: athlete) {
			lines += lap(samples, startingAt: start, offset: offset, from: lapStartDistance)
			offset += samples.count
			lapStartDistance = samples.last?.distance ?? lapStartDistance
		}
		lines += ["</Activity>", "</Activities>", "</TrainingCenterDatabase>"]
		return lines.joined(separator: "\n") + "\n"
	}

	private static func lap(
		_ samples: [SeedSample], startingAt start: Date, offset: Int, from startDistance: Double
	) -> [String] {
		let count = Double(max(samples.count, 1))
		let distance = (samples.last?.distance ?? startDistance) - startDistance
		let watts = samples.compactMap(\.watts)
		let cadences = samples.compactMap(\.cadence)
		let kilojoules = Double(watts.reduce(0, +)) / 1_000
		var lines = [
			#"<Lap StartTime="\#(stamp(start.addingTimeInterval(Double(offset))))">"#,
			"<TotalTimeSeconds>\(samples.count)</TotalTimeSeconds>",
			"<DistanceMeters>\(decimal(distance, 1))</DistanceMeters>",
			"<Calories>\(Int(watts.isEmpty ? count * 0.2 : kilojoules.rounded()))</Calories>",
			"<AverageHeartRateBpm><Value>\(Int((Double(samples.map(\.heartRate).reduce(0, +)) / count).rounded()))</Value></AverageHeartRateBpm>",
			"<MaximumHeartRateBpm><Value>\(samples.map(\.heartRate).max() ?? 0)</Value></MaximumHeartRateBpm>",
			"<Intensity>Active</Intensity>",
		]
		if !cadences.isEmpty {
			lines.append(
				"<Cadence>\(Int((Double(cadences.reduce(0, +)) / count).rounded()))</Cadence>")
		}
		lines += ["<TriggerMethod>Manual</TriggerMethod>", "<Track>"]
		for (index, sample) in samples.enumerated() {
			lines.append(trackpoint(sample, at: start.addingTimeInterval(Double(offset + index))))
		}
		lines.append("</Track>")
		var summary = "<ns3:AvgSpeed>\(decimal(distance / count, 3))</ns3:AvgSpeed>"
		if !watts.isEmpty {
			summary +=
				"<ns3:AvgWatts>\(Int((Double(watts.reduce(0, +)) / count).rounded()))</ns3:AvgWatts>"
		}
		lines += ["<Extensions><ns3:LX>\(summary)</ns3:LX></Extensions>", "</Lap>"]
		return lines
	}

	private static func trackpoint(_ sample: SeedSample, at time: Date) -> String {
		var point =
			"<Trackpoint><Time>\(stamp(time))</Time><DistanceMeters>\(decimal(sample.distance, 1))</DistanceMeters><HeartRateBpm><Value>\(sample.heartRate)</Value></HeartRateBpm>"
		if let cadence = sample.cadence {
			point += "<Cadence>\(cadence)</Cadence>"
		}
		var extensions = "<ns3:Speed>\(decimal(sample.speed, 3))</ns3:Speed>"
		if let watts = sample.watts {
			extensions += "<ns3:Watts>\(watts)</ns3:Watts>"
		}
		return point + "<Extensions><ns3:TPX>\(extensions)</ns3:TPX></Extensions></Trackpoint>"
	}

	private static func rideSpeed(watts: Double) -> Double {
		let rolling = 0.0045 * 82 * 9.81
		let drag = 0.5 * 1.2 * 0.3
		let power = max(watts, 20)
		var speed = 8.0
		for _ in 0..<8 {
			speed -=
				(rolling * speed + drag * speed * speed * speed - power)
				/ (rolling + 3 * drag * speed * speed)
		}
		return speed
	}

	private static func decimal(_ value: Double, _ places: Int) -> String {
		String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
	}

	private static func stamp(_ date: Date) -> String {
		date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
	}
}
