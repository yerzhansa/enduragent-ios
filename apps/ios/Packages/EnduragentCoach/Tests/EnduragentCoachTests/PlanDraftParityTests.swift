import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PlanDraftParityTests {
	private static let fixtureOptions = PlanDraftOptions(
		id: "fixture", createdAt: "1970-01-01T00:00:00.000Z", totalWeeks: nil)

	@Test func everyRecordedProfileGetsNpmsPlanDraftOnThePhonesDay() throws {
		let files = try PlanFixtures.planDraftFiles()
		var compared = 0
		var mismatched: [String] = []
		for file in files {
			for item in try PlanFixtures.cases(file) {
				compared += 1
				if let problem = try Self.mismatch(item) { mismatched.append(problem) }
			}
		}
		#expect(
			mismatched.isEmpty,
			"\(mismatched.count) cases differ from npm, first: \(mismatched.prefix(3))")
		#expect(compared == (try PlanFixtures.manifestCount(files)))
		#expect(compared > 0)
	}

	@Test(arguments: Array(50...600))
	func draftZonesAreTheZoneCalculatorsRows(ftpWatts: Int) throws {
		let profile = PlanProfile(
			experience: .intermediate, ftpWatts: ftpWatts, weightKg: nil, volumeTier: .medium,
			schedule: ScheduleInput(
				type: .flexible, availableDays: nil, keySessionDay: nil, sessionsPerWeek: nil),
			goal: GoalInput(
				type: .general, raceType: nil, raceDate: nil, targetTime: nil, generalGoal: nil,
				generalGoalTarget: nil))
		let draft = try Planning.draft(profile, today: "1998-06-13", options: Self.fixtureOptions)
		let tables = try #require(draft.json.objectFields["zoneTables"]?.arrayValue)
		let zones = try #require(tables.first?.objectFields["zones"]?.arrayValue)
		let rows = try DisplayZones.table(ftpWatts: ftpWatts)
		#expect(tables.count == 1)
		#expect(zones.map { $0.objectFields["name"]?.stringValue } == rows.map(\.label))
		#expect(zones.map { $0.objectFields["range"]?.stringValue } == rows.map(\.value))
	}

	private static func mismatch(_ item: PlanFixtures.Case) throws -> String? {
		let instant = try #require(item.instant, "\(item.id) records no instant")
		let zone = try #require(item.timeZone, "\(item.id) records no time zone")
		let today = try #require(item.today, "\(item.id) records no today")
		guard IntervalsPolicy.today(now: instant, timeZone: zone) == today else {
			return "\(item.id) is another day on the phone"
		}
		let profile: PlanProfile
		do {
			profile = try PlanningArguments.profile(item.input)
		} catch {
			return "\(item.id) refused: \(error.details)"
		}
		let draft: PlanDraft
		do {
			draft = try Planning.draft(profile, today: today, options: fixtureOptions)
		} catch {
			return item.thrown == nil ? "\(item.id) threw \(error)" : nil
		}
		guard item.thrown == nil else { return "\(item.id) gave a draft where npm threw" }
		guard let output = item.output, draft.json == output else { return item.id }
		guard output.objectFields["totalWeeks"] == .number(Double(draft.totalWeeks)) else {
			return "\(item.id) carries another week count"
		}
		return nil
	}
}
