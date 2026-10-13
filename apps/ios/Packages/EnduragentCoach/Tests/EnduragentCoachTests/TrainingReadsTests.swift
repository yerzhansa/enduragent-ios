import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TrainingReadsTests {
	let intervals = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

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

	@Test(arguments: [(13.1, 13.1), (7.46, 7.5), (0.25, 0.3), (-0.25, -0.2), (-6.47, -6.5)])
	func oneDecimalRoundsATieTowardPositiveInfinity(value: Double, rounded: Double) {
		#expect(OneDecimal.round(value) == rounded)
	}

	@Test func formNeedsBothFitnessAndFatigue() {
		#expect(WellnessDay.on("1998-06-13", [.fitness: 42]).form == nil)
		#expect(WellnessDay.on("1998-06-13", [.fatigue: 49, .reportedFatigue: 2]).form == nil)
	}

	@Test func wellnessToolKeepsStoredOrderAndTodaysFields() async throws {
		intervals.wellness = [
			.on("1998-06-13", [.fitness: 55.2, .fatigue: 42.1, .reportedFatigue: 2, .hrv: 62.5]),
			.on("1998-06-06", [.fitness: 40]),
			.on("1998-06-11"),
			.on("1998-06-12", [.fatigue: 0]),
		]
		let days = try await result(
			of: .intervalsFetchWellness, #"{"oldest":"1998-06-07","newest":"1998-06-13"}"#)
		#expect(
			days
				== .array([
					.object([
						"date": .string("1998-06-13"), "fitness": .number(55.2),
						"fatigue": .number(42.1), "form": .number(55.2 - 42.1),
					]),
					.object(["date": .string("1998-06-11")]),
					.object(["date": .string("1998-06-12"), "fatigue": .number(0)]),
				]))
	}

	@Test func reversedWellnessRangeIsRefusedBeforeAnyRead() async throws {
		let refused = try await result(
			of: .intervalsFetchWellness, #"{"oldest":"1998-06-13","newest":"1998-06-07"}"#)
		#expect(refused.objectFields["error"] == .string("invalid_range"))
		#expect(intervals.count(of: .wellness) == 0)
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

	private func result(of tool: ToolName, _ arguments: String) async throws -> JSONValue {
		let ledger = Ledger(
			log: InMemoryRecordLog(), clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let outcome = try await makeToolRuntime(intervals: intervals, ledger: ledger, clock: clock)
			.execute(
				name: tool, arguments: try JSONValue.parse(arguments),
				scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
			).outcome
		guard case .result(let json) = outcome else {
			throw IntervalsError(code: "test", details: "expected a tool result")
		}
		return try #require(json.objectFields["data"])
	}
}
