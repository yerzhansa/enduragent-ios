import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LiveSeedPlanTests {
	static let today: CivilDate = "2026-10-14"
	static let athlete = SeedAthlete(ftp: 250, lthr: 172, maxHeartRate: 190)

	@Test func theThresholdRideReadsBackWithOneLapPerBlockAndTotalsThatAddUp() throws {
		let plan = LiveSeedPlan(anchor: Self.today)
		let threshold = try #require(plan.activities.first { $0.key == "threshold" })
		let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
		let tcx = try TCXReading.read(
			try LiveSeedTCX.document(of: threshold, athlete: Self.athlete, timeZone: berlin))

		#expect(tcx.sport == "Biking")
		#expect(tcx.id == "2026-10-12T15:30:00Z")
		#expect(tcx.laps.first?.points.first?.time == tcx.id)
		#expect(tcx.laps.map(\.seconds) == [900, 600, 300, 600, 300, 600, 600])
		#expect(tcx.laps.map { Double($0.points.count) } == tcx.laps.map(\.seconds))
		let points = tcx.laps.flatMap(\.points)
		#expect(points.allSatisfy { $0.watts != nil && $0.heartRate != nil && $0.cadence != nil })
		#expect(points.allSatisfy { ($0.heartRate ?? 999) <= Self.athlete.maxHeartRate })
		let lapDistance = tcx.laps.map(\.distance).reduce(0, +)
		#expect(abs(lapDistance - (points.last?.distance ?? 0)) < 1)
		for lap in tcx.laps {
			let mean = lap.points.compactMap(\.watts).reduce(0, +) / Double(lap.points.count)
			#expect(abs((lap.averageWatts ?? -1) - mean) <= 0.5)
		}
		for interval in [1, 3, 5] {
			#expect((235...265).contains(tcx.laps[interval].averageWatts ?? 0))
		}
		#expect((110...140).contains(tcx.laps[2].averageWatts ?? 0))
	}

	@Test func aRecordingWithoutPowerHasNoWattsAndTheRunHasNoBikeCadence() throws {
		let plan = LiveSeedPlan(anchor: Self.today)
		for key in ["heart-rate-only", "run-off-the-bike"] {
			let activity = try #require(plan.activities.first { $0.key == key })
			let document = try LiveSeedTCX.document(
				of: activity, athlete: Self.athlete, timeZone: .gmt)
			let tcx = try TCXReading.read(document)
			let points = tcx.laps.flatMap(\.points)
			#expect(points.count == activity.seconds)
			#expect(points.allSatisfy { $0.watts == nil && $0.heartRate != nil })
			#expect(tcx.laps.allSatisfy { $0.averageWatts == nil })
			#expect(!document.contains("Watts"))
		}
		let run = try #require(plan.activities.first { $0.key == "run-off-the-bike" })
		let tcx = try TCXReading.read(
			try LiveSeedTCX.document(of: run, athlete: Self.athlete, timeZone: .gmt))
		#expect(tcx.sport == "Running")
		#expect(tcx.laps.flatMap(\.points).allSatisfy { $0.cadence == nil })
	}

	@Test func thePlanPutsEachScenarioOnItsDayCountedBackFromToday() throws {
		let plan = LiveSeedPlan(anchor: Self.today)
		let byKey = Dictionary(uniqueKeysWithValues: plan.activities.map { ($0.key, $0) })
		let threshold = try #require(byKey["threshold"])
		#expect(threshold.start == SeedStart("2026-10-12", 17, 30))
		#expect(threshold.blocks.map(\.seconds) == [900, 600, 300, 600, 300, 600, 600])
		#expect(threshold.blocks.filter { $0.from >= 0.95 }.count == 3)

		let week = plan.activities.filter { $0.start.date >= Self.today.adding(days: -6) }
		let rides = week.filter { $0.sport == .ride }
		#expect(rides.count >= 2)
		#expect(
			rides.max {
				($0.start.date, $0.start.secondOfDay) < ($1.start.date, $1.start.secondOfDay)
			}
				== threshold)
		#expect(week.allSatisfy { $0.feel != nil && $0.rpe != nil })
		#expect(Set(week.compactMap(\.feel)).count >= 3)
		#expect(Set(week.compactMap(\.rpe)).count >= 4)
		#expect(!plan.activities.contains { $0.start.date > Self.today.adding(days: -2) })

		let ride = try #require(byKey["openers-ride"])
		let run = try #require(byKey["run-off-the-bike"])
		#expect(run.sport == .run && ride.start.date == run.start.date)
		#expect(run.start.secondOfDay - ride.endSecondOfDay == 600)
		#expect(run.start.secondOfDay - ride.start.secondOfDay <= 30 * 60)
		#expect(byKey["heart-rate-only"]?.recordsPower == false)
		#expect(byKey["second-ride"]?.sport == .ride)

		let base = plan.activities.filter { $0.key.hasPrefix("base-") }
		#expect(base.count == 20)
		#expect(base.allSatisfy { (45 * 60...120 * 60).contains($0.seconds) && $0.sport == .ride })
		#expect(base.contains { $0.blocks.contains { $0.from >= 0.85 } })
		#expect(base.map(\.start.date).min() == "2026-09-03")
		#expect(base.map(\.start.date).max() == "2026-10-06")
		#expect(Set(plan.activities.map(\.externalID)).count == plan.activities.count)
		#expect(plan.activities.allSatisfy { $0.externalID.hasPrefix("enduragent-seed-") })
		#expect(plan.activities.allSatisfy { $0.name.hasPrefix("[synthetic] ") })

		let first: CivilDate = "2026-09-03"
		#expect(plan.wellness.map(\.date) == (0..<42).map { first.adding(days: $0) })
		#expect(plan.wellness.allSatisfy { Set($0.values.keys) == Set(SeedWellnessDay.fields) })
		#expect(plan.wellness.allSatisfy { (30...200).contains($0.values["weight"] ?? 0) })
		#expect(plan.wellness.allSatisfy { (20...150).contains($0.values["hrv"] ?? 0) })
		#expect(Set(plan.wellness.compactMap { $0.values["restingHR"] }).count > 1)

		let again = LiveSeedPlan(anchor: Self.today)
		#expect(again.activities == plan.activities && again.wellness == plan.wellness)
	}
}
