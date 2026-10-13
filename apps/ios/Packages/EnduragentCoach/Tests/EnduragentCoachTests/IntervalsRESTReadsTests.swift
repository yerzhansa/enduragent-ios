import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Test func profileTakesCyclingSettingsBeforeAthleteFields() async throws {
		let profile = try await makeClient().profile()
		#expect(profile.id == "i1001")
		#expect(profile.name == "Ada Kovač")
		#expect(profile.ftp == .usable(try #require(FTPWatts(250))))
		#expect(profile.readings[.lthr] == 165)
		#expect(profile.readings[.maxHeartRate] == 185)
		#expect(profile.readings[.restingHeartRate] == 48)
		#expect(profile.readings[.weight] == 58)
	}

	@Test func profileKeepsTheAddedFieldsOfTheCyclingRowAndTheAthlete() async throws {
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		let profile = try await makeClient(clock: clock).profile()
		#expect(
			profile
				== AthleteProfile.cyclist(id: "i1001", name: "Ada Kovač", ftp: 250).with(
					[
						.lthr: 165, .maxHeartRate: 185, .restingHeartRate: 48, .weight: 58,
						.indoorFTP: 245, .wPrime: 20_000, .maxPower: 1_100, .sweetSpotMin: 84,
						.sweetSpotMax: 97,
					],
					sex: "F", ageYears: 27, settingsSports: ["Ride", "VirtualRide"],
					powerZones: zip(
						[
							"Active Recovery", "Endurance", "Tempo", "Threshold", "VO2 Max",
							"Anaerobic", "Neuromuscular",
						], [55, 75, 90, 105, 120, 150, 999]
					).map(TrainingZone.init),
					heartRateZones: zip(
						[
							"Recovery", "Aerobic", "Tempo", "SubThreshold", "SuperThreshold",
							"Aerobic Capacity", "Anaerobic",
						], [135, 150, 156, 166, 171, 176, 185]
					).map(TrainingZone.init)))
	}

	@Test(arguments: ProfileChainStep.all)
	func profileUsesTheFirstSourceThatHasAValue(step: ProfileChainStep) async throws {
		let profile = try await profile(from: step.body)
		#expect(step.chain.value(in: profile) == step.expected)
	}

	@Test func profileWithNoSourceHasNoFTPAndNoReadings() async throws {
		let profile = try await profile(from: #"{"id":"i1001","name":"Ada","sportSettings":[]}"#)
		#expect(profile.ftp == .absent)
		for field in ProfileField.allCases {
			#expect(profile.readings[field] == nil)
		}
	}

	@Test(arguments: ["Ride", "VirtualRide", "MountainBikeRide", "GravelRide", "EBikeRide"])
	func cyclingRowIsTheFirstRowWithACyclingSport(sport: String) async throws {
		let profile = try await profile(
			from: """
				{"id":"i1001","name":"Ada","sportSettings":[
				{"types":["Run"],"lthr":171},
				{"types":["Swim","\(sport)"],"lthr":162},
				{"types":["\(sport)"],"lthr":153}]}
				""")
		#expect(profile.readings[.lthr] == 162)
	}

	@Test func profileWithoutACyclingRowReadsTheFirstRow() async throws {
		let profile = try await profile(
			from: """
				{"id":"i1001","name":"Ada","sportSettings":[
				{"types":["Run"],"lthr":171},{"types":["Swim"],"lthr":162}]}
				""")
		#expect(profile.readings[.lthr] == 171)
	}

	@Test(arguments: [#""abc""#, "true", "[250]"])
	func ftpThatIsNotANumberIsImplausibleAndKeepsLaterSourcesOut(ftp: String) async throws {
		let profile = try await profile(
			from: """
				{"id":"i1001","name":"Ada","icu_ftp":250,
				"sportSettings":[{"types":["Ride"],"ftp":\(ftp)}]}
				""")
		#expect(profile.ftp == .implausible(reported: nil))
	}

	@Test func ftpOutsideTheBandKeepsItsNumber() async throws {
		let profile = try await profile(
			from: #"{"id":"i1001","name":"Ada","sportSettings":[{"types":["Ride"],"ftp":2500}]}"#)
		#expect(profile.ftp == .implausible(reported: 2500))
	}

	@Test func wellnessDecodesEveryField() async throws {
		let days = try await makeClient().wellness(
			in: try ReadRange(oldest: "1998-06-10", newest: nil, today: "1998-06-13"))
		#expect(
			IntervalsURLProtocolStub.lastRequest?.url?.query
				== "oldest=1998-06-10&newest=1998-06-13")
		let day = try #require(days.first { $0.date == "1998-06-13" })
		let expected: [WellnessField: Double] = [
			.fitness: 55.2, .fatigue: 42.1, .rampRate: 1.4, .weight: 58.4, .restingHeartRate: 47,
			.hrv: 62.5, .sleepSeconds: 25_500, .sleepScore: 81, .sleepQuality: 2, .readiness: 74,
			.soreness: 3, .stress: 1, .mood: 4, .motivation: 5, .injury: 6, .reportedFatigue: 2,
		]
		for field in WellnessField.allCases {
			#expect(day.readings[field] == expected[field], "\(field)")
		}
		#expect(day.fatigue == 42.1)
	}

	@Test func wellnessKeepsSourceOrderZerosAndGaps() async throws {
		let days = try await makeClient().wellness(
			in: try ReadRange(oldest: "1998-06-10", newest: "1998-06-13", today: "1998-06-13"))
		#expect(days.map(\.date) == ["1998-06-12", "1998-06-13", "1998-06-11", "1998-06-10"])
		#expect(days[2] == .on("1998-06-11"))
		#expect(days[3] == .on("1998-06-10", [.fitness: 53.9, .sleepSeconds: 0, .soreness: 0]))
		#expect(days[3].form == nil)
		#expect(
			days[0]
				== .on(
					"1998-06-12",
					[
						.fitness: 54.8, .fatigue: 40, .rampRate: 1.1, .reportedFatigue: 3,
					]))
	}

	@Test func wellnessLeavesOutARowWithoutARealDate() async throws {
		let client = try makeClient()
		IntervalsURLProtocolStub.handler = { _ in
			(
				200,
				Data(
					#"[{"id":"1998-02-30","ctl":50},{"ctl":51},{"id":"1998-06-13","ctl":55}]"#.utf8)
			)
		}
		#expect(
			try await client.wellness(in: .day("1998-06-13")) == [
				.on("1998-06-13", [.fitness: 55])
			])
	}

	@Test func wellnessThatIsNotAListFailsTheRead() async throws {
		let client = try makeClient()
		IntervalsURLProtocolStub.handler = { _ in (200, Data(#"{"error":"busy"}"#.utf8)) }
		await #expect(
			throws: IntervalsError(
				code: "invalid_json", details: "wellness response was not an array")
		) {
			try await client.wellness(in: .day("1998-06-13"))
		}
	}

	private func profile(from body: String) async throws -> AthleteProfile {
		let client = try makeClient()
		IntervalsURLProtocolStub.handler = { _ in (200, Data(body.utf8)) }
		return try await client.profile()
	}
}

enum ProfileChain: CaseIterable, Sendable {
	case ftp
	case lthr
	case maxHeartRate
	case restingHeartRate
	case weight

	var sources: [(onSettings: Bool, key: String)] {
		switch self {
		case .ftp: [(true, "ftp"), (false, "icu_ftp")]
		case .lthr: [(true, "lthr"), (false, "icu_lthr")]
		case .maxHeartRate: [(true, "max_hr"), (false, "icu_max_hr")]
		case .restingHeartRate: [(true, "resting_hr"), (false, "icu_resting_hr")]
		case .weight: [(false, "icu_weight"), (false, "weight"), (true, "weight")]
		}
	}

	func value(in profile: AthleteProfile) -> Double? {
		switch self {
		case .ftp:
			guard case .usable(let watts) = profile.ftp else { return nil }
			return watts.value
		case .lthr: return profile.readings[.lthr]
		case .maxHeartRate: return profile.readings[.maxHeartRate]
		case .restingHeartRate: return profile.readings[.restingHeartRate]
		case .weight: return profile.readings[.weight]
		}
	}
}

struct ProfileChainStep: Sendable, CustomTestStringConvertible {
	enum Gap: String, CaseIterable, Sendable {
		case missing
		case null
	}

	let chain: ProfileChain
	let winner: Int
	let gap: Gap

	static let all: [ProfileChainStep] = ProfileChain.allCases.flatMap { chain in
		chain.sources.indices.flatMap { winner in
			(winner == 0 ? [Gap.missing] : Gap.allCases).map {
				ProfileChainStep(chain: chain, winner: winner, gap: $0)
			}
		}
	}

	var testDescription: String {
		"\(chain) from source \(winner + 1), earlier sources \(gap.rawValue)"
	}

	var expected: Double { Double(100 + winner * 10) }

	var body: String {
		var athlete: [String: JSONValue] = ["id": .string("i1001"), "name": .string("Ada")]
		var cycling: [String: JSONValue] = ["types": .array([.string("Ride")])]
		var running: [String: JSONValue] = ["types": .array([.string("Run")])]
		for (index, source) in chain.sources.enumerated() {
			if source.onSettings { running[source.key] = .number(999) }
			let value: JSONValue
			if index >= winner {
				value = .number(Double(100 + index * 10))
			} else if gap == .null {
				value = .null
			} else {
				continue
			}
			if source.onSettings {
				cycling[source.key] = value
			} else {
				athlete[source.key] = value
			}
		}
		athlete["sportSettings"] = .array([.object(running), .object(cycling)])
		return JSONValue.object(athlete).canonicalDigestInput()
	}
}
