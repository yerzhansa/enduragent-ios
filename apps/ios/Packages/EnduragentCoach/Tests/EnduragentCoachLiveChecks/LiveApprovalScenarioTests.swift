import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

private struct ApprovalBenchTraining: TrainingClient {
	let reads: FakeIntervalsClient
	let calendar: FakeSeedCalendar

	func profile() async throws -> AthleteProfile { try await reads.profile() }

	func wellness(in range: ReadRange) async throws -> [WellnessDay] {
		try await reads.wellness(in: range)
	}

	func activities(in range: ReadRange) async throws -> ActivityListing {
		try await reads.activities(in: range)
	}

	func activity(_ id: ActivityID) async throws -> ActivityDetailRead {
		try await reads.activity(id)
	}

	func streams(of id: ActivityID, channels: StreamChannels) async throws -> StreamSummary {
		try await reads.streams(of: id, channels: channels)
	}

	func fetchEvent(id: EventID) async throws -> CalendarEvent { try calendar.fetchEvent(id: id) }

	func listEvents(in range: ReadRange) async throws -> [CalendarEvent] {
		calendar.listEvents(in: range)
	}

	func write(_ write: CalendarWrite) async -> IntervalsWriteAnswer { calendar.write(write) }
}

private struct ApprovalBenchRig {
	enum Behavior {
		case faithful
		case stray
	}

	static let athlete = "i-ada"

	let calendar = FakeSeedCalendar()
	let model: FakeModelTransport
	let seeded: [CalendarEvent]
	let scenarios: [LiveScenario]
	let today: CivilDate
	let thursday: CivilDate
	let ledgerFile: URL

	init(coach behavior: Behavior, ledgerAthlete: String?) throws {
		let today = IntervalsPolicy.today(now: Date(), timeZone: .current)
		self.today = today
		seeded = calendar.add(LiveSeedCalendar.entries.map { $0.requestBody(seededOn: today) })
		scenarios = try LiveReviewScenarioTests.plan(seeded, today: today).scenarios.filter {
			$0.setting == .approving
		}
		let added = scenarios.first?.turns.first?.expectations.compactMap {
			expectation -> CivilDate? in
			guard case .review(.holds(_, let changes)) = expectation,
				case .add(let date)? = changes.first
			else { return nil }
			return date
		}
		thursday = try #require(added?.first)
		ledgerFile = try TestTemporaryFolders.make().appending(path: "ledger.tsv")
		var ledger = try LiveSeedLedger(file: ledgerFile)
		if let ledgerAthlete { try ledger.record(athlete: ledgerAthlete) }
		let ride = ReviewBenchRig.ride(on: thursday, minutes: 60)
		let strength = ReviewBenchRig.strength(on: thursday.adding(days: 2), minutes: 30)
		let repeated = ReviewBenchRig.ride(on: today.adding(days: 1), minutes: 15)
		let (rideTurn, strengthTurn, question, repeating) = (
			scenarios[0].turns[0].message, scenarios[1].turns[1].message,
			scenarios[0].turns[1].message, scenarios[1].turns[2].message
		)
		let prepares = { (change: String) in
			[ReviewBenchRig.complete([change]), ReviewBenchRig.reply]
		}
		let steps: [String: [ReviewBenchRig.Step]] =
			switch behavior {
			case .faithful:
				[
					rideTurn: prepares(ride), strengthTurn: prepares(strength),
					question: [ReviewBenchRig.reply], repeating: prepares(repeated),
				]
			case .stray:
				[
					rideTurn: prepares(ride), strengthTurn: prepares(strength),
					question: prepares(ride), repeating: [ReviewBenchRig.reply],
				]
			}
		model = FakeModelTransport(respond: ReviewBenchRig.respond(to: steps))
	}

	func runAll() async throws -> [LiveScenarioRun] {
		let training = ApprovalBenchTraining(
			reads: FakeIntervalsClient(athleteName: "Ada", ftp: 250), calendar: calendar)
		let model = model
		let bench = LiveCoachBench(
			intervalsKey: "synthetic-intervals-key", openRouterKey: "synthetic-model-key",
			athlete: IntervalsAthleteID(rawValue: Self.athlete),
			model: try LiveCoachBench.builtInModel(),
			ledger: try LiveSpendLedger(
				file: try TestTemporaryFolders.make().appending(path: "spend.tsv"),
				milestone: .m4, limit: 100),
			today: today, modelTransport: { _ in model }, accountReads: { _, _ in training },
			seedLedger: ledgerFile)
		var runs: [LiveScenarioRun] = []
		for scenario in scenarios {
			runs.append(try await bench.run(scenario, attempt: 1))
		}
		return runs
	}

	var creates: Int {
		calendar.writes.filter { FakeSeedCalendar.WriteKind($0) == .create }.count
	}
}

@Suite struct LiveApprovalScenarioTests {
	@Test func aFaithfulCoachPassesAndEveryApprovedAddIsRemovedAfterwards() async throws {
		let rig = try ApprovalBenchRig(coach: .faithful, ledgerAthlete: ApprovalBenchRig.athlete)

		let runs = try await rig.runAll()

		#expect(runs.map(\.violations) == [[], []])
		#expect(runs.flatMap { $0.turns.compactMap(\.approval?.creates) } == [1, 1, 1])
		#expect(rig.calendar.events.map(\.id) == rig.seeded.map(\.id))
		#expect(try LiveSeedLedger(file: rig.ledgerFile).calendar.isEmpty)
	}

	@Test func aCoachThatPreparesAgainOrSkipsTheRepeatFailsAndStillLeavesNothingBehind()
		async throws
	{
		let rig = try ApprovalBenchRig(coach: .stray, ledgerAthlete: ApprovalBenchRig.athlete)

		let runs = try await rig.runAll()

		let approved = try #require(runs.first).violations
		#expect(approved.contains("turn 2: prepare_workout_changes was called"))
		#expect(approved.contains("turn 2: the waiting review changed"))
		let repeated = try #require(runs.last).violations
		#expect(
			repeated.contains(
				"turn 3: prepare_workout_changes drafted a review with kinds [], not once with kind complete"
			))
		#expect(repeated.contains("cancel: no review waited to cancel"))
		#expect(rig.calendar.events.map(\.id) == rig.seeded.map(\.id))
	}

	@Test(arguments: [
		(
			"i-other",
			"nothing was approved: the seed ledger belongs to athlete i-other, but the key belongs to athlete i-ada."
		),
		(
			nil,
			"nothing was approved: the seed ledger names no athlete. Run make live-seed first."
		),
	])
	func aLedgerThatDoesNotNameTheKeysAthleteStopsBeforeAnyModelCall(
		ledgerAthlete: String?, stop: String
	) async throws {
		let rig = try ApprovalBenchRig(coach: .faithful, ledgerAthlete: ledgerAthlete)

		let runs = try await rig.runAll()

		#expect(runs.map(\.violations) == [[stop], [stop]])
		#expect(runs.allSatisfy { $0.turns.isEmpty })
		#expect(rig.model.requestCount == 0)
		#expect(rig.creates == 0)
	}
}
