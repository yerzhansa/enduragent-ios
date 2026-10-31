import EnduragentCoachFixtures
import Foundation
import Synchronization

@testable import EnduragentCoach

final class LiveCalendarRequests: Sendable {
	private let counts = Mutex((reads: 0, writes: 0))

	var reads: Int { counts.withLock { $0.reads } }
	var writes: Int { counts.withLock { $0.writes } }
	var total: Int { counts.withLock { $0.reads + $0.writes } }

	func read() {
		counts.withLock { $0.reads += 1 }
	}

	func refuse() -> IntervalsWriteAnswer {
		counts.withLock { $0.writes += 1 }
		return .httpStatus(403)
	}
}

struct LiveReadOnlyTraining: TrainingReads, IntervalsClient {
	let inner: any TrainingClient
	let requests: LiveCalendarRequests
	var approvals: LiveApprovalCalendar? = nil

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
		requests.read()
		return try await inner.fetchEvent(id: id)
	}

	func listEvents(in range: ReadRange) async throws -> [CalendarEvent] {
		requests.read()
		return try await inner.listEvents(in: range)
	}

	func write(_ write: CalendarWrite) async -> IntervalsWriteAnswer {
		if let approvals, let answer = await approvals.write(write, through: inner) {
			return answer
		}
		return requests.refuse()
	}
}

struct LiveScenarioRun: Sendable {
	let attempt: Int
	let turns: [LiveTurnRecord]
	var cancel: LiveCancelRecord?
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
	var seedLedger: URL? = nil
	var records: @Sendable () -> any ReviewChainLog = { InMemoryRecordLog() }

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
		let missing = try await missingTargets(of: scenario)
		guard missing.isEmpty else { return Self.unrun(scenario, attempt: attempt, missing) }
		var approvals: LiveApprovalCalendar?
		if scenario.setting == .approving {
			do {
				approvals = try LiveApprovalCalendar.open(seedLedger, for: athlete)
			} catch {
				return Self.unrun(scenario, attempt: attempt, [LiveCalendarSweep.describe(error)])
			}
		}
		let log = LiveExchangeLog()
		let requests = LiveCalendarRequests()
		let coach = try await coach(
			for: scenario.setting, log: log, requests: requests, approvals: approvals)
		let played: (turns: [LiveTurnRecord], cancel: LiveCancelRecord?)
		do {
			played = try await play(
				scenario, on: coach, log: log, requests: requests, approvals: approvals)
		} catch {
			let left = await end(coach, approvals)
			guard left.isEmpty else {
				let stopped = "the scenario stopped on \(LiveCalendarSweep.describe(error))"
				throw LiveCheckStop(description: ([stopped] + left).joined(separator: "; "))
			}
			throw error
		}
		let (turns, cancel) = played
		var violations = await end(coach, approvals)
		for (number, pair) in zip(turns, scenario.turns).enumerated() {
			violations += LiveVerdict.violations(of: pair.0, against: pair.1.expectations).map {
				"turn \(number + 1): \($0)"
			}
			if pair.1.tapsSavePlan {
				violations += LivePlanVerdict.violations(ofTap: pair.0.tap).map {
					"turn \(number + 1) tap: \($0)"
				}
			}
			if pair.1.approvesReview {
				violations += LiveVerdict.violations(ofApproval: pair.0.approval).map {
					"turn \(number + 1) approval: \($0)"
				}
			}
		}
		if turns.count < scenario.turns.count {
			violations.append("the scenario stopped after turn \(turns.count)")
		}
		if scenario.endsWithCancel {
			violations += LiveVerdict.violations(ofCancel: cancel).map { "cancel: \($0)" }
		}
		let transcript = LiveTranscript.markdown(
			scenario, attempt: attempt, turns: turns, cancel: cancel, violations: violations)
		return LiveScenarioRun(
			attempt: attempt, turns: turns, cancel: cancel, violations: violations,
			transcript: transcript)
	}

	private func play(
		_ scenario: LiveScenario, on coach: Coach, log: LiveExchangeLog,
		requests: LiveCalendarRequests, approvals: LiveApprovalCalendar?
	) async throws -> (turns: [LiveTurnRecord], cancel: LiveCancelRecord?) {
		var turns: [LiveTurnRecord] = []
		var latestDraft: JSONValue?
		for plan in scenario.turns {
			let before = try await coach.ledger.reviewHead(chat: .main).1
			let savedBefore = try await savedPlan(of: coach)
			let state: TurnState?
			let outcome: String
			var accepted: TurnID?
			do {
				let sent = try await coach.send(draft(plan.message), to: .main)
				accepted = sent.acceptedTurn
				if let turn = accepted {
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
			var record = LiveTurnRecord(
				message: plan.message, exchanges: log.drain(),
				reply: state.flatMap(replyText), outcome: outcome,
				reviewPending: try await coach.desk.snapshot(chat: .main) != nil,
				calendarWrites: requests.writes,
				reviewBefore: before, reviewAfter: try await coach.ledger.reviewHead(chat: .main).1,
				notice: snapshot?.turns.first { $0.id == accepted }?.reviewNotice?.key,
				plans: snapshot?.plans ?? [], savedBefore: savedBefore)
			latestDraft = record.results(of: .buildPlanSkeleton).last ?? latestDraft
			record.draft = latestDraft
			record.prepared = try await preparedPlan(of: coach, for: record.waitingPlans.last)
			if plan.tapsSavePlan { record.tap = await tapSavePlan(on: coach) }
			if plan.approvesReview {
				record.approval = try await approveWaitingReview(of: coach, approvals)
			}
			record.savedAfter = try await savedPlan(of: coach)
			turns.append(record)
			if record.reply == nil { break }
		}
		let cancel =
			scenario.endsWithCancel ? try await cancelWaitingReview(of: coach, requests) : nil
		return (turns, cancel)
	}

	private func end(_ coach: Coach, _ approvals: LiveApprovalCalendar?) async -> [String] {
		await coach.lifecycle(.willTerminate)
		guard let approvals else { return [] }
		return await approvals.removeCreated(
			through: accountReads(.apiKey(intervalsKey), .keyOwner))
	}

	private static func unrun(_ scenario: LiveScenario, attempt: Int, _ violations: [String])
		-> LiveScenarioRun
	{
		LiveScenarioRun(
			attempt: attempt, turns: [], violations: violations,
			transcript: LiveTranscript.markdown(
				scenario, attempt: attempt, turns: [], cancel: nil, violations: violations))
	}

	private func missingTargets(of scenario: LiveScenario) async throws -> [String] {
		guard !scenario.targets.isEmpty else { return [] }
		let calendar = try await accountReads(.apiKey(intervalsKey), .keyOwner).listEvents(
			in: try LiveSeedCalendar.window(around: today))
		return scenario.targets.compactMap { $0.presence(in: calendar) }
	}

	private enum Armed {
		case nothingWaits
		case refused(String)
		case armed(ReviewControlToken)
	}

	private func armWaitingReview(of coach: Coach) async throws -> Armed {
		guard let shown = try await coach.desk.snapshot(chat: .main) else { return .nothingWaits }
		let presented = await coach.decide(.presented(shown.ref), in: .main)
		guard case .armed(_, let token)? = try await coach.desk.snapshot(chat: .main)?.controls
		else { return .refused("never armed: the presentation answered \(presented)") }
		return .armed(token)
	}

	private func approveWaitingReview(of coach: Coach, _ approvals: LiveApprovalCalendar?)
		async throws -> LiveApprovalRecord?
	{
		guard let approvals else {
			return LiveApprovalRecord(
				outcome: "not approved: only the approving setting writes to the calendar",
				completed: false, creates: 0, problems: [], waitingAfter: true)
		}
		switch try await armWaitingReview(of: coach) {
		case .nothingWaits:
			return nil
		case .refused(let outcome):
			return LiveApprovalRecord(
				outcome: outcome, completed: false, creates: 0, problems: [], waitingAfter: true)
		case .armed(let token):
			return try await approvals.approve(token, on: coach)
		}
	}

	private func cancelWaitingReview(of coach: Coach, _ requests: LiveCalendarRequests)
		async throws -> LiveCancelRecord?
	{
		let token: ReviewControlToken
		switch try await armWaitingReview(of: coach) {
		case .nothingWaits:
			return nil
		case .refused(let outcome):
			return LiveCancelRecord(
				outcome: outcome, canceled: false, calendarRequests: 0, waitingAfter: true)
		case .armed(let armed):
			token = armed
		}
		let sent = requests.total
		let outcome = await coach.decide(.cancel(token), in: .main)
		let made = requests.total - sent
		let canceled = if case .canceled = outcome { true } else { false }
		return LiveCancelRecord(
			outcome: "\(outcome)", canceled: canceled, calendarRequests: made,
			waitingAfter: try await coach.desk.snapshot(chat: .main) != nil)
	}

	private func savedPlan(of coach: Coach) async throws -> PlanDocument? {
		try await coach.memory.savedPlans(for: try await coach.vault.connectedAccount()).newest
	}

	private func preparedPlan(of coach: Coach, for card: PlanCard?) async throws -> PlanDocument? {
		guard let card else { return nil }
		let steps = try await coach.ledger.read(.planChain(of: .main)).records.compactMap(
			PlanStepRecord.init)
		for step in steps where step.body.confirmation == card.id {
			if case .prepared(let prepared) = step.body.step { return prepared.document }
		}
		return nil
	}

	private func tapSavePlan(on coach: Coach) async -> LivePlanTap? {
		let waiting = LiveTurnRecord.waiting
		guard let shown = await coach.currentSnapshot(.main)?.plans.last(where: waiting) else {
			return nil
		}
		let presented = await coach.decide(.presented(shown.ref), in: .main)
		guard
			case .waiting(.armed(let token))? = await coach.currentSnapshot(.main)?.plans.first(
				where: { $0.id == shown.id })?.state
		else {
			return LivePlanTap(
				outcome: "never armed: the presentation answered \(presented)", saved: false)
		}
		let outcome = await coach.decide(.save(token), in: .main)
		return LivePlanTap(outcome: "\(outcome)", saved: outcome == .saved)
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

	private func coach(
		for setting: LiveSetting, log: LiveExchangeLog, requests: LiveCalendarRequests,
		approvals: LiveApprovalCalendar?
	) async throws -> Coach {
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: openRouterKey))
		let reads: TrainingService.ClientFactory
		var snapshotFailing: FakeIntervalsClient?
		switch setting {
		case .connected, .reviewing, .approving:
			try secrets.storeIntervalsConnection(
				IntervalsConnection(
					id: ConnectionID(), credential: .apiKey(intervalsKey), selection: .keyOwner,
					resolvedAthlete: athlete))
			reads = accountReads
		case .notConnected:
			let unused = FakeIntervalsClient(athleteName: "Unconnected athlete", ftp: 250)
			reads = { _, _ in unused }
		case .readsFailing:
			try secrets.storeIntervalsConnection(testConnection)
			let failing = FakeIntervalsClient(athleteName: "Live check athlete", ftp: 250)
			snapshotFailing = failing
			reads = { _, _ in failing }
		case .implausibleFTP:
			try secrets.storeIntervalsConnection(testConnection)
			let athlete = FakeIntervalsClient(
				athleteName: "Live check athlete", ftp: LiveCoachPlan.implausibleFTP)
			athlete.wellness = [.on(today, [.fitness: 48, .fatigue: 52])]
			reads = { _, _ in athlete }
		}
		let ledger = self.ledger
		let coach = Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: RecordStore(log: records()), secrets: secrets,
				models: ModelService { [modelTransport] diagnostics in
					LiveMeteredTransport(
						inner: modelTransport(diagnostics), ledger: ledger, log: log)
				},
				training: TrainingService { credential, selection in
					LiveReadOnlyTraining(
						inner: reads(credential, selection), requests: requests,
						approvals: approvals)
				},
				credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
				clock: SystemClock(), support: .inMemory(app: .fixture)),
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
