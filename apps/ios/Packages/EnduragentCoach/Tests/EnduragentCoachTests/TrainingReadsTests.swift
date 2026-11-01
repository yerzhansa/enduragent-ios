import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TrainingReadsTests {
	let intervals = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250)

	@Test(arguments: [50.0, 250, 600])
	func ftpInsideTheBandIsUsable(watts: Double) throws {
		#expect(FTPReading(.number(watts)) == .usable(try #require(FTPWatts(watts))))
	}

	@Test(arguments: [49.9, 600.1, 0, -250, 2500])
	func ftpOutsideTheBandIsImplausibleWithItsNumber(watts: Double) {
		#expect(FTPReading(.number(watts)) == .implausible(reported: watts))
	}

	@Test func ftpWithoutANumberIsAbsentOrImplausible() {
		#expect(FTPReading(.absent) == .absent)
		#expect(FTPReading(.notANumber) == .implausible(reported: nil))
	}

	@Test func readingsKeepAZeroAndHaveNoEntryForWhatIsMissing() {
		let readings = Readings<WellnessField>([.soreness: 0, .hrv: .nan, .weight: .infinity])
		#expect(readings[.soreness] == 0)
		#expect(readings[.hrv] == nil)
		#expect(readings[.weight] == nil)
		#expect(readings[.mood] == nil)
	}

	@Test(arguments: [(55.2, 42.1), (42.0, 49.0), (50.0, 42.54), (0.0, 0.25), (0.0, 0.0)])
	func formIsFitnessMinusFatigueUnrounded(fitness: Double, fatigue: Double) {
		#expect(
			WellnessDay.on("1998-06-13", [.fitness: fitness, .fatigue: fatigue]).form
				== fitness - fatigue)
	}

	@Test func formNeedsBothFitnessAndFatigue() {
		#expect(WellnessDay.on("1998-06-13", [.fitness: 42]).form == nil)
		#expect(WellnessDay.on("1998-06-13", [.fatigue: 49, .reportedFatigue: 2]).form == nil)
	}

	@Test func heldReadEndsWithCancellationWhenItsTaskIsCancelled() async throws {
		let gate = intervals.hold(.wellness)
		let release: @Sendable () -> Void = { Task { await gate.release() } }
		let reading = Task { [intervals] in try await intervals.wellness(in: .day("1998-06-13")) }
		try #require(
			try await beforeDeadline(within: .hangGuard, onTimeout: release) {
				await gate.waitUntilEntered()
			} != nil)
		reading.cancel()
		let ended = try await beforeDeadline(within: .hangGuard, onTimeout: release) {
			await reading.result
		}
		guard case .failure(let error)? = ended else {
			Issue.record(
				"expected the held read to end with an error, got \(String(describing: ended))")
			return
		}
		#expect(error is CancellationError)
	}

	@Test func failedReadThrowsUntilRestoredOrOnce() async throws {
		let outage = IntervalsError(code: "http", details: "status 503", status: 503)
		intervals.fail(.profile, with: outage)
		await #expect(throws: outage) { try await intervals.profile() }
		await #expect(throws: outage) { try await intervals.profile() }
		intervals.restore(.profile)
		#expect(try await intervals.profile().name == "Ada Kovač")
		intervals.fail(.wellness, with: outage, once: true)
		await #expect(throws: outage) { try await intervals.wellness(in: .day("1998-06-13")) }
		#expect(try await intervals.wellness(in: .day("1998-06-13")).isEmpty)
		#expect(intervals.count(of: .profile) == 3)
		#expect(intervals.count(of: .wellness) == 2)
	}
}
