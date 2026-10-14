import CryptoKit
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
		let afternoon = try #require(byKey["afternoon-ride"])
		#expect(afternoon.sport == .ride && afternoon.start.date == ride.start.date)
		#expect(afternoon.start.secondOfDay - run.endSecondOfDay >= 2 * 3_600)
		#expect(
			plan.activities.filter { $0.start.date == afternoon.start.date && $0 != afternoon }
				.allSatisfy { abs($0.start.secondOfDay - afternoon.start.secondOfDay) > 30 * 60 })
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

	@Test func theActivitiesAndWellnessTheAccountAlreadyHoldsAreUnchangedByTheAfternoonRide()
		throws
	{
		let plan = LiveSeedPlan(anchor: Self.today)
		let held = try plan.activities.filter { $0.key != "afternoon-ride" }.map { activity in
			let document = try LiveSeedTCX.document(
				of: activity, athlete: Self.athlete, timeZone: .gmt)
			let digest = SHA256.hash(data: Data(document.utf8)).prefix(6)
				.map { String(format: "%02x", $0) }.joined()
			return [
				activity.externalID, activity.start.date.rawValue,
				String(
					format: "%02d:%02d", activity.start.secondOfDay / 3_600,
					activity.start.secondOfDay / 60 % 60),
				"\(activity.seconds)s", "feel \(activity.feel.map(String.init) ?? "-")",
				"rpe \(activity.rpe.map(String.init) ?? "-")",
				"tcx \(document.utf8.count) \(digest)",
			].joined(separator: " ")
		}
		let wellness = plan.wellness.flatMap { day in
			SeedWellnessDay.fields.map { "\(day.date.rawValue) \($0) \(day.values[$0] ?? -1)" }
		}.joined(separator: "\n")
		let wellnessDigest = SHA256.hash(data: Data(wellness.utf8)).prefix(6)
			.map { String(format: "%02x", $0) }.joined()

		#expect(
			held == [
				"enduragent-seed-base-01 2026-09-03 06:30 3300s feel - rpe - tcx 875034 355c77e06cda",
				"enduragent-seed-base-02 2026-09-05 06:30 4200s feel - rpe - tcx 1113502 a2de3f93fcbe",
				"enduragent-seed-base-03 2026-09-07 17:45 4800s feel - rpe - tcx 1272506 8bb02683e167",
				"enduragent-seed-base-04 2026-09-08 08:00 6600s feel - rpe - tcx 1752218 c4006793baa6",
				"enduragent-seed-base-05 2026-09-10 06:30 4200s feel - rpe - tcx 1113527 b90c6c1abd2e",
				"enduragent-seed-base-06 2026-09-12 06:30 4200s feel - rpe - tcx 1113535 b97fcbe6f08b",
				"enduragent-seed-base-07 2026-09-14 17:45 2700s feel - rpe - tcx 715997 20425f98ef8c",
				"enduragent-seed-base-08 2026-09-15 08:00 7200s feel - rpe - tcx 1908516 953d0315e5f8",
				"enduragent-seed-base-09 2026-09-17 06:30 3300s feel - rpe - tcx 875028 0a0aac729cc7",
				"enduragent-seed-base-10 2026-09-19 06:30 4500s feel - rpe - tcx 1195621 22a887497319",
				"enduragent-seed-base-11 2026-09-21 17:45 4200s feel - rpe - tcx 1113515 5ad53c899f60",
				"enduragent-seed-base-12 2026-09-22 08:00 6900s feel - rpe - tcx 1829018 b11186624328",
				"enduragent-seed-base-13 2026-09-24 06:30 5100s feel - rpe - tcx 1354580 b4906ba46bba",
				"enduragent-seed-base-14 2026-09-26 06:30 3600s feel - rpe - tcx 954537 f9bbc0941565",
				"enduragent-seed-base-15 2026-09-28 17:45 5100s feel - rpe - tcx 1352008 e9de63f2e5e4",
				"enduragent-seed-base-16 2026-09-29 08:00 5700s feel - rpe - tcx 1513533 15309d5c4a36",
				"enduragent-seed-base-17 2026-10-01 06:30 3600s feel - rpe - tcx 954520 e1bafa14b50f",
				"enduragent-seed-base-18 2026-10-03 06:30 4200s feel - rpe - tcx 1113507 2e5605156c92",
				"enduragent-seed-base-19 2026-10-05 17:45 4200s feel - rpe - tcx 1113526 4044bba3b14d",
				"enduragent-seed-base-20 2026-10-06 08:00 6900s feel - rpe - tcx 1829035 88c4af34c1cd",
				"enduragent-seed-heart-rate-only 2026-10-08 06:45 3300s feel 2 rpe 3 tcx 789095 bec02c052a53",
				"enduragent-seed-second-ride 2026-10-09 07:00 4500s feel 1 rpe 4 tcx 1193014 ffa7e5294592",
				"enduragent-seed-openers-ride 2026-10-10 08:00 900s feel 2 rpe 5 tcx 239854 d67768199f1f",
				"enduragent-seed-run-off-the-bike 2026-10-10 08:25 1800s feel 3 rpe 6 tcx 391838 d18402f66166",
				"enduragent-seed-threshold 2026-10-12 17:30 3900s feel 4 rpe 8 tcx 1037820 9ef79fb945ff",
			])
		#expect(wellnessDigest == "c548f5807538")
		#expect(plan.activities.count == held.count + 1)
	}
}
