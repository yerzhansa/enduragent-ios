import EnduragentCoachFixtures
import Foundation
import Synchronization

@testable import EnduragentCoach

final class LiveCalendarWrites: Sendable {
	private let count = Mutex(0)

	var total: Int { count.withLock { $0 } }

	func refuse() -> IntervalsError {
		count.withLock { $0 += 1 }
		return IntervalsError(
			code: "live_check_read_only", details: "The live check never writes the calendar.")
	}
}

struct LiveReadOnlyTraining: TrainingReads, IntervalsClient {
	let inner: any TrainingClient
	let writes: LiveCalendarWrites

	func profile() async throws -> AthleteProfile { try await inner.profile() }

	func wellness(in range: ReadRange) async throws -> [WellnessDay] {
		try await inner.wellness(in: range)
	}

	func activities(in range: ReadRange) async throws -> ActivityListing {
		try await inner.activities(in: range)
	}

	func activity(_ id: ActivityID) async throws -> ActivityDetailRead {
		try await inner.activity(id)
	}

	func streams(of id: ActivityID, channels: StreamChannels) async throws -> StreamSummary {
		try await inner.streams(of: id, channels: channels)
	}

	func fetchEvent(id: EventID) async throws -> CalendarEvent {
		try await inner.fetchEvent(id: id)
	}

	func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		try await inner.listEvents(oldest: oldest, newest: newest)
	}

	func createChatEvent(_ draft: ChatCalendarCreate) async throws -> CalendarEvent {
		throw writes.refuse()
	}

	func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{
		throw writes.refuse()
	}

	func deleteEvent(id: EventID) async throws {
		throw writes.refuse()
	}
}

struct LiveScenarioRun: Sendable {
	let attempt: Int
	let turns: [LiveTurnRecord]
	let violations: [String]
	let transcript: String

	var passed: Bool { violations.isEmpty }
}

struct LiveCoachBench: Sendable {
	let intervalsKey: String
	let openRouterKey: String
	let athlete: IntervalsAthleteID?
	let model: ModelID
	let ledger: LiveSpendLedger
	let today: CivilDate
	let modelTransport: @Sendable (DiagnosticsLog) -> any ModelTransport
	let accountReads: TrainingService.ClientFactory

	static func builtInModel() throws -> ModelID {
		let ios = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in
			path.deletingLastPathComponent()
		}
		let project = try String(contentsOf: ios.appending(path: "project.yml"), encoding: .utf8)
		guard
			let setting = project.split(separator: "\n").first(where: {
				$0.trimmingCharacters(in: .whitespaces).hasPrefix("OPENROUTER_MODEL:")
			}), let raw = setting.split(separator: " ").last
		else {
			throw LiveCheckStop(description: "apps/ios/project.yml names no OPENROUTER_MODEL")
		}
		return ModelID(rawValue: String(raw))
	}

	func run(_ scenario: LiveScenario, attempt: Int) async throws -> LiveScenarioRun {
		ledger.label("\(scenario.name)#\(attempt)")
		let log = LiveExchangeLog()
		let writes = LiveCalendarWrites()
		let coach = try await coach(for: scenario.setting, log: log, writes: writes)
		var turns: [LiveTurnRecord] = []
		for plan in scenario.turns {
			let state: TurnState?
			let outcome: String
			do {
				let sent = try await coach.send(draft(plan.message), to: .main)
				if let turn = sent.acceptedTurn {
					state = await coach.settledState(
						of: turn, in: .main, within: .subject(.seconds(300)))
					outcome = state.map(Self.outcome) ?? "unsettled after 300 seconds"
				} else {
					state = nil
					outcome = "not accepted: \(sent)"
				}
			} catch {
				state = nil
				outcome = "refused: \(error)"
			}
			let snapshot = await coach.currentSnapshot(.main)
			let record = LiveTurnRecord(
				message: plan.message, exchanges: log.drain(),
				reply: state.flatMap(replyText), outcome: outcome,
				reviewPending: snapshot?.review != nil, calendarWrites: writes.total)
			turns.append(record)
			if record.reply == nil { break }
		}
		await coach.lifecycle(.willTerminate)
		var violations: [String] = []
		for (number, pair) in zip(turns, scenario.turns).enumerated() {
			violations += LiveVerdict.violations(of: pair.0, against: pair.1.expectations).map {
				"turn \(number + 1): \($0)"
			}
		}
		if turns.count < scenario.turns.count {
			violations.append("the scenario stopped after turn \(turns.count)")
		}
		let transcript = LiveTranscript.markdown(
			scenario, attempt: attempt, turns: turns, violations: violations)
		return LiveScenarioRun(
			attempt: attempt, turns: turns, violations: violations, transcript: transcript)
	}

	static func outcome(of state: TurnState) -> String {
		switch state {
		case .completed: "completed"
		case .savedWork: "with saved work"
		case .failed(let failed): "failed: \(failed.failure)"
		case .interrupted(let interrupted): "interrupted: \(interrupted.cause)"
		case .accepted, .processing, .unrecovered: "unsettled"
		}
	}

	private func coach(for setting: LiveSetting, log: LiveExchangeLog, writes: LiveCalendarWrites)
		async throws -> Coach
	{
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: openRouterKey))
		let reads: TrainingService.ClientFactory
		var snapshotFailing: FakeIntervalsClient?
		switch setting {
		case .connected:
			try secrets.storeIntervalsConnection(
				IntervalsConnection(
					id: ConnectionID(), credential: .apiKey(intervalsKey), selection: .keyOwner,
					resolvedAthlete: athlete))
			reads = accountReads
		case .notConnected:
			let unused = FakeIntervalsClient(athleteName: "Unconnected athlete", ftp: 250)
			reads = { _, _, _ in unused }
		case .readsFailing:
			try secrets.storeIntervalsConnection(testConnection)
			let failing = FakeIntervalsClient(athleteName: "Live check athlete", ftp: 250)
			snapshotFailing = failing
			reads = { _, _, _ in failing }
		case .implausibleFTP:
			try secrets.storeIntervalsConnection(testConnection)
			let athlete = FakeIntervalsClient(
				athleteName: "Live check athlete", ftp: LiveCoachPlan.implausibleFTP)
			athlete.wellness = [.on(today, [.fitness: 48, .fatigue: 52])]
			reads = { _, _, _ in athlete }
		}
		let ledger = self.ledger
		let coach = Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: RecordStore(log: InMemoryRecordLog()), secrets: secrets,
				models: ModelService { [modelTransport] diagnostics in
					LiveMeteredTransport(
						inner: modelTransport(diagnostics), ledger: ledger, log: log)
				},
				training: TrainingService { credential, selection, clock in
					LiveReadOnlyTraining(inner: reads(credential, selection, clock), writes: writes)
				},
				credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
				clock: SystemClock()),
			builtInModel: model, displayLocale: testDisplayLocale)
		if case .required(let challenge) = await coach.vault.accessConsent(
			builtInModel: coach.builtInModel, recorded: nil)
		{
			try await coach.recordConsent(challenge)
		}
		if let snapshotFailing {
			_ = try await coach.vault.trainingConnection()
			for read in [FakeTrainingRead.profile, .wellness] {
				snapshotFailing.fail(
					read,
					with: IntervalsError(
						code: "network", details: "intervals.icu could not be reached."))
			}
		}
		return coach
	}
}
