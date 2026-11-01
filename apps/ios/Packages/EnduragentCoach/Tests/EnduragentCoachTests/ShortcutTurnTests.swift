import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ShortcutTurnTests {
	@Test(arguments: [
		("/status", SlashCommand.status),
		("/status how is my Form this week", .status),
		("/workout", .workout),
		("/workout 45 minutes indoors", .workout),
		("/plan", .plan),
		("/plan for my gran fondo in June", .plan),
	])
	func shortcutReachesTheCoachOnceWithAllItsText(text: String, command: SlashCommand)
		async throws
	{
		let bench = ShortcutBench()
		let coach = try await bench.coach()

		let request = try await bench.onlyRequest(after: text, to: coach)

		#expect(request.charge == .chatAttempt)
		#expect(request.messages.map(\.role) == [.system, .user])
		#expect(request.messages.last?.content == text + "\n" + ShortcutBench.timeLine)
		let stored = try await bench.storedMessages()
		#expect(stored.map(\.athleteText) == [text])
		#expect(stored.map(\.slash) == [command])
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.map(\.athleteText) == [text])
		#expect(snapshot.turns.compactMap { replyText($0.state) } == [ShortcutBench.reply])
	}

	@Test(arguments: [
		("/status", "How is my Form this week?"),
		("/status how is my Form this week", "How is my Form this week?"),
		("/workout", "What is today's workout?"),
		("/workout 45 minutes indoors", "What is today's workout?"),
	])
	func shortcutAndOrdinaryMessageGiveTheCoachTheSamePromptAndTools(
		shortcut: String, ordinary: String
	) async throws {
		let typed = ShortcutBench()
		let asked = ShortcutBench()

		let command = try await typed.onlyRequest(after: shortcut, to: try await typed.coach())
		let plain = try await asked.onlyRequest(after: ordinary, to: try await asked.coach())

		let system = try #require(command.messages.first)
		#expect(system.role == .system)
		#expect(system.content.contains("Profile: FTP 250 W\nWellness 1998-06-13: Fitness 55.2"))
		#expect(system.content.contains("\n# Cycling Prescription Availability\n"))
		#expect(
			system.content.contains(
				"The /workout command asks for a workout described in your reply, not a calendar change: prepare a review for it only when the athlete then asks to schedule it."
			))
		#expect(plain.messages.first == system)
		#expect(command.tools.contains { $0.name == .intervalsFetchWellness })
		#expect(command.tools.contains { $0.name == .prepareWorkoutChanges })
		#expect(plain.tools == command.tools)
		#expect(
			command.messages.dropFirst().map(\.content) == [
				shortcut + "\n" + ShortcutBench.timeLine
			])
		#expect(
			plain.messages.dropFirst().map(\.content) == [ordinary + "\n" + ShortcutBench.timeLine])
		#expect(try await asked.storedMessages().map(\.athleteText) == [ordinary])
		#expect(try await asked.storedMessages().map(\.slash) == [nil])
	}

	@Test func planShortcutOffersThePlanningToolsAndThePromptOfThePlainMessage() async throws {
		let shortcut = "/plan for my gran fondo in June"
		let ordinary = "Build me a training plan for my gran fondo in June"
		let typed = ShortcutBench()
		let asked = ShortcutBench()

		let command = try await typed.onlyRequest(after: shortcut, to: try await typed.coach())
		let plain = try await asked.onlyRequest(after: ordinary, to: try await asked.coach())

		let offered = Set(command.tools.map(\.name))
		#expect(offered.isSuperset(of: [.buildPlanSkeleton, .assessFeasibility, .getSampleWeek]))
		#expect(plain.tools == command.tools)
		#expect(command.messages.first?.role == .system)
		#expect(plain.messages.first == command.messages.first)
		#expect(
			command.messages.dropFirst().map(\.content) == [
				shortcut + "\n" + ShortcutBench.timeLine
			])
		#expect(
			plain.messages.dropFirst().map(\.content) == [ordinary + "\n" + ShortcutBench.timeLine])
		#expect(try await typed.storedMessages().map(\.slash) == [.plan])
		#expect(try await asked.storedMessages().map(\.slash) == [nil])
	}

	@Test(arguments: AccessRefusal.allCases)
	func planWithNoUsableModelAccessEndsWithTheAccessNoticeAndNoCard(refusal: AccessRefusal)
		async throws
	{
		let bench = ShortcutBench()
		let coach = try await bench.coach(refusal: refusal)

		let turn = try #require(
			try await coach.send(draft("/plan for my gran fondo in June"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))

		#expect(failure(settled) == .model(.accessUnavailable(refusal.unavailable)))
		#expect(turnNotice(of: settled)?.actions == refusal.actions(for: turn))
		#expect(replyText(settled) == nil)
		#expect(bench.transport.requests.isEmpty)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.map(\.athleteText) == ["/plan for my gran fondo in June"])
		#expect(snapshot.turns.map(\.state) == [settled])
		#expect(snapshot.plans.isEmpty)
		#expect(snapshot.liveReply == nil)
		#expect(snapshot.activity == .idle)
		let confirmations = try await bench.store.fetch(
			RecordQuery(scope: .deviceLocal([PlanChain.kind])))
		#expect(confirmations.records.isEmpty)
		#expect(
			try await bench.store.fetch(RecordQuery(scope: .synced([SavedPlans.kind]))).records
				.isEmpty)
	}

	@Test(arguments: ["1998-06-13", "1998-06-10"])
	func statusPromptCarriesTheWellnessLineWithItsRowsDate(date: String) async throws {
		let row = try #require(CivilDate(rawValue: date))
		let bench = ShortcutBench(wellness: [.on(row, [.fitness: 55.2, .fatigue: 42.1])])

		let request = try await bench.onlyRequest(after: "/status", to: try await bench.coach())

		let system = try bench.system(of: request)
		#expect(
			system.contains(
				"""
				# Athlete Profile & Latest Wellness

				Profile: FTP 250 W
				Wellness \(date): Fitness 55.2 · Fatigue 42.1 · Form +13.1
				\(PromptStaticBlocks.snapshotGuidance)
				"""))
		#expect(system.components(separatedBy: "Wellness 1998-06-").count == 2)
		#expect(!system.contains(PromptStaticBlocks.snapshotFallback))
	}

	@Test(arguments: MissingWellness.allCases)
	func statusPromptWithoutUsableWellnessKeepsOnlyTheProfileLine(missing: MissingWellness)
		async throws
	{
		let bench = ShortcutBench(wellness: [.on("1998-06-05", [.fitness: 55.2, .fatigue: 42.1])])
		let coach = try await bench.coach()
		if missing == .readFailed { bench.intervals.fail(.wellness, with: ShortcutBench.outage) }

		let request = try await bench.onlyRequest(after: "/status", to: coach)

		let system = try bench.system(of: request)
		#expect(
			system.contains(
				"""
				# Athlete Profile & Latest Wellness

				Profile: FTP 250 W
				\(PromptStaticBlocks.snapshotGuidance)
				"""))
		#expect(!system.contains("Wellness 1998-06-"))
		#expect(!system.contains(PromptStaticBlocks.snapshotFallback))
	}

	@Test func statusPromptHoldsTheFallbackWhenBothReadsHaveNothing() async throws {
		let bench = ShortcutBench()
		let coach = try await bench.coach()
		bench.intervals.fail(.profile, with: ShortcutBench.outage)
		bench.intervals.fail(.wellness, with: ShortcutBench.outage)

		let request = try await bench.onlyRequest(after: "/status", to: coach)

		let system = try bench.system(of: request)
		#expect(
			system.contains(
				"""
				# Athlete Profile & Latest Wellness

				Athlete snapshot: unavailable this turn; fetch the profile and latest wellness \
				before prescribing intensity.

				---
				"""))
		#expect(!system.contains("Profile:"))
		#expect(!system.contains("Wellness 1998-06-"))
	}

	@Test(arguments: ["/status", "/workout"])
	func unconnectedShortcutPromptSaysSoAndOffersNoTrainingTool(text: String) async throws {
		let bench = ShortcutBench()
		let coach = try await bench.coach(connected: false)

		let request = try await bench.onlyRequest(after: text, to: coach)

		let system = try bench.system(of: request)
		#expect(system.contains(PromptAssembly.snapshotSection(.notConnected)))
		#expect(!system.contains("Profile:"))
		#expect(!system.contains(PromptStaticBlocks.snapshotFallback))
		#expect(request.tools.contains { $0.name == .memoryQuery })
		#expect(!request.tools.contains { $0.name.rawValue.hasPrefix("intervals_") })
		#expect(bench.intervals.count(of: .profile) == 0)
		#expect(bench.intervals.count(of: .wellness) == 0)
	}

	@Test(arguments: ["/status", "/workout", "/workout 45 minutes indoors"])
	func shortcutEndingInTextLeavesNoReviewAndMakesNoCalendarCall(text: String) async throws {
		let bench = ShortcutBench()
		let coach = try await bench.coach()

		_ = try await bench.onlyRequest(after: text, to: coach)

		#expect(try #require(await coach.currentSnapshot(.main)).review == nil)
		#expect(try await bench.savedReviews() == 0)
		#expect(bench.intervals.calls.filter(\.isCalendarCall).isEmpty)
		#expect(bench.intervals.events.isEmpty)
	}

	@Test(arguments: WorkoutProgress.allCases)
	func runningWorkoutShowsTheMessageAndAWorkingStateWithNoFinishedReply(
		reached: WorkoutProgress
	) async throws {
		let bench = ShortcutBench()
		let coach = try await bench.coach(replying: reached.opening + [.hang])

		let turn = try #require(
			try await coach.send(draft("/workout 45 minutes indoors"), to: .main).acceptedTurn)
		try await waitUntil { bench.transport.requests.count == 1 }
		let running = try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
				guard case .processing? = $0.turns.first?.state else { return false }
				return ($0.liveReply?.text ?? "") == reached.streamed
			})

		#expect(running.turns.map(\.id) == [turn])
		#expect(running.turns.map(\.athleteText) == ["/workout 45 minutes indoors"])
		#expect(running.activity == .working(label: Catalog.chatNoticeWorking))
		#expect(running.turns.compactMap { replyText($0.state) }.isEmpty)
		#expect(running.review == nil)
		await coach.stop(.main)
		let stopped = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(stopped) == nil)
	}

	@Test(arguments: WorkoutProgress.allCases)
	func workoutLosingModelAccessEndsWithANoticeAndNoReplyReviewOrCalendarCall(
		lost: WorkoutProgress
	) async throws {
		let bench = ShortcutBench()
		let dropped = lost.opening + [ScriptedEvent.fail(.connection(.networkConnectionLost))]
		let coach = try await bench.coach(replying: dropped + dropped + dropped)

		let turn = try #require(try await coach.send(draft("/workout"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))

		#expect(failure(settled) == .model(.providerDown(.network)))
		let notice = try #require(turnNotice(of: settled))
		#expect(
			notice.canonicalSentence
				== "The model provider is having trouble — try again in a few minutes.")
		#expect(notice.actions == [.tryAgain(turn)])
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.map(\.athleteText) == ["/workout"])
		#expect(snapshot.turns.map(\.state) == [settled])
		#expect(snapshot.liveReply == nil)
		#expect(snapshot.activity == .idle)
		#expect(snapshot.review == nil)
		#expect(try await bench.savedReviews() == 0)
		#expect(bench.intervals.calls.filter(\.isCalendarCall).isEmpty)
		#expect(bench.intervals.events.isEmpty)
	}
}

enum AccessRefusal: CaseIterable {
	case missingKey
	case lockedKeychain

	var unavailable: AccessUnavailable {
		switch self {
		case .missingKey: .notConfigured(.credits)
		case .lockedKeychain: .secureStorageLocked
		}
	}

	func actions(for turn: TurnID) -> [RecoveryAction] {
		switch self {
		case .missingKey: [.chooseAccessMethod]
		case .lockedKeychain: [.tryAgain(turn)]
		}
	}
}

enum MissingWellness: CaseIterable {
	case noRowInSevenDays
	case readFailed
}

enum WorkoutProgress: CaseIterable {
	case beforeAnyText
	case afterPartialText

	var streamed: String {
		switch self {
		case .beforeAnyText: ""
		case .afterPartialText: "Start with "
		}
	}

	var opening: [ScriptedEvent] {
		streamed.isEmpty ? [] : [.text(streamed)]
	}
}

struct ShortcutBench {
	static let reply = "Form is steady."
	static let timeLine =
		"Current time: Saturday, June 13th, 1998 - 08:00 (Europe/Amsterdam) / 1998-06-13 06:00 UTC"
	static let outage = IntervalsError(code: "http", details: "status 503", status: 503)

	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	init(wellness: [WellnessDay] = [.on("1998-06-13", [.fitness: 55.2, .fatigue: 42.1])]) {
		intervals.wellness = wellness
	}

	func coach(
		connected: Bool = true, refusal: AccessRefusal? = nil,
		replying script: [ScriptedEvent] = [.text(reply), .finish(reason: .stop)]
	) async throws -> Coach {
		transport.respond = ScriptedReply.sequence(
			script, for: .chat, otherwise: transport.respond)
		let backing = FixtureSecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: backing)
		if refusal != .missingKey {
			try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		}
		if connected { try secrets.storeIntervalsConnection(testConnection) }
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock,
			secrets: secrets)
		_ = try await coach.vault.trainingConnection()
		if refusal == .lockedKeychain { backing.locked = true }
		return coach
	}

	func onlyRequest(after text: String, to coach: Coach) async throws -> CompletionRequest {
		let settled = try await coach.sendAndSettle(text)
		#expect(replyText(settled) == Self.reply)
		#expect(transport.requests.count == 1)
		return try #require(transport.requests.first)
	}

	func system(of request: CompletionRequest) throws -> String {
		let system = try #require(request.messages.first)
		#expect(system.role == .system)
		return system.content
	}

	func storedMessages() async throws -> [UserMessageBody] {
		try await store.fetch(RecordQuery(scope: .synced([.userMessage]))).records.compactMap {
			guard case .synced(.userMessage(let body)) = $0.body else { return nil }
			return body
		}
	}

	func savedReviews() async throws -> Int {
		try await store.fetch(RecordQuery(scope: .deviceLocal([.workoutReview]))).records.count
	}
}
