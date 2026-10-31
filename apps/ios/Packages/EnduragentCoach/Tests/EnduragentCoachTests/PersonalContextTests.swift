import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(2))) struct PersonalContextTests {
	struct Athlete {
		let key: FixtureTrainingPeer.Key
		let goals: String
		let availability: String
		let equipment: String

		var injected: [(SectionName, String)] { [(.goals, goals), (.schedule, availability)] }
		var everything: [String] { [goals, availability, equipment] }
	}

	let mira = Athlete(
		key: .rotatedA,
		goals: "- Finish the Alpine gran fondo in September.",
		availability: "- Rides Tuesday, Thursday and Sunday mornings.",
		equipment: "- Carbon road bike with a crank power meter.")
	let bo = Athlete(
		key: .athleteB,
		goals: "- Win the club ten-mile time trial in May.",
		availability: "- Rides Monday and Friday evenings, long ride Saturday.",
		equipment: "- Steel gravel bike on a direct-drive trainer.")
	let fixture: AthleteScopedCoachingFixture

	init() throws {
		fixture = try AthleteScopedCoachingFixture(store: InMemoryRecordLog())
	}

	@Test func eachAthletesRequestCarriesOnlyTheirOwnGoalsAndAvailability() async throws {
		let coach = await fixture.open()
		try await remember(mira.injected + [(.cyclingEquipment, mira.equipment)], using: coach)
		try await fixture.connect(bo.key, using: coach)
		try await remember(bo.injected + [(.cyclingEquipment, bo.equipment)], using: coach)

		let forBo = try await ask(coach)
		try await fixture.connect(mira.key, using: coach)
		let forMira = try await ask(coach)

		for (request, own, other) in [(forBo, bo, mira), (forMira, mira, bo)] {
			let context = try MemoryProbe.athleteData(in: MemoryProbe.systemText(in: request))
			#expect(context.contains("## goals\n"))
			#expect(context.contains(own.goals))
			#expect(context.contains("## schedule\n"))
			#expect(context.contains(own.availability))
			for text in other.everything {
				#expect(request.messages.allSatisfy { !$0.content.contains(text) })
			}
		}
		await coach.lifecycle(.willTerminate)
	}

	@Test func equipmentStaysOutOfThePromptAndComesBackOnlyThroughMemoryRead() async throws {
		let coach = await fixture.open()
		try await remember(mira.injected, using: coach)
		#expect(!(try await ask(coach)).tools.map(\.name).contains(.memoryRead))

		try await remember([(.cyclingEquipment, mira.equipment)], using: coach)
		let forMira = try await readMemory(coach)
		try await fixture.connect(bo.key, using: coach)
		try await remember(bo.injected, using: coach)
		let boWithoutEquipment = try await ask(coach)
		try await remember([(.cyclingEquipment, bo.equipment)], using: coach)
		let forBo = try await readMemory(coach)
		try await fixture.connect(mira.key, using: coach)
		let forMiraAfterBo = try await readMemory(coach)

		#expect(!boWithoutEquipment.tools.map(\.name).contains(.memoryRead))
		for (request, own, other) in [
			(forMira, mira, bo), (forBo, bo, mira), (forMiraAfterBo, mira, bo),
		] {
			let system = try MemoryProbe.systemText(in: request)
			#expect(system.contains(own.goals))
			#expect(!system.contains(own.equipment))
			#expect(!system.contains("## \(SectionName.cyclingEquipment.rawValue)"))
			#expect(request.tools.map(\.name).contains(.memoryRead))
			let read = try MemoryProbe.text(
				in: #require(request.messages.last { $0.role == .tool }))
			#expect(read.contains("## \(SectionName.cyclingEquipment.rawValue)\n"))
			#expect(read.contains(own.equipment))
			#expect(!read.contains(other.equipment))
		}
		await coach.lifecycle(.willTerminate)
	}

	@Test func rewrittenGoalReplacesTheOldOneAndStaysInTheRecordOfChanges() async throws {
		let rewritten = "- Ride the two-day coastal brevet in October."
		let coach = await fixture.open()
		try await remember(mira.injected, using: coach)
		#expect(try MemoryProbe.systemText(in: try await ask(coach)).contains(mira.goals))

		try await remember([(.goals, rewritten)], using: coach)
		let system = try MemoryProbe.systemText(in: try await ask(coach))

		let context = try MemoryProbe.athleteData(in: system)
		#expect(context.contains(rewritten))
		#expect(context.contains(mira.availability))
		#expect(!system.contains(mira.goals))
		let changes = try await goalChanges()
		#expect(
			changes.contains { change in
				change["oldBody"]?.stringValue?.contains(mira.goals) == true
					&& change["newBody"]?.stringValue?.contains(rewritten) == true
			})
		await coach.lifecycle(.willTerminate)
	}

	@Test func promptSaysNoPlanIsSavedAndOffersPlanSaveThenPlanLoad() async throws {
		let coach = await fixture.open()
		try await remember(mira.injected + [(.cyclingEquipment, mira.equipment)], using: coach)

		let request = try await ask(coach)

		let system = try MemoryProbe.systemText(in: request)
		#expect(system.contains(mira.goals))
		#expect(system.contains("## Current Plan\nNo plan saved yet."))
		let offered = request.tools.map(\.name.rawValue)
		#expect(offered.contains("memory_write"))
		#expect(
			Array(offered.drop { $0 != "calculate_zones" }.prefix(4)) == [
				"calculate_zones", "build_plan_skeleton", "assess_feasibility", "get_sample_week",
			])
		#expect(offered.filter { $0.hasPrefix("plan_") } == ["plan_save", "plan_load"])
		#expect(offered.last == "plan_load")
		await coach.lifecycle(.willTerminate)
	}

	@Test func everyPromptEndsItsAthleteContextWithThePlanBlock() async throws {
		let noPlan = "## Current Plan\nNo plan saved yet."
		let coach = await fixture.open()
		let empty = try MemoryProbe.athleteData(
			in: MemoryProbe.systemText(in: try await ask(coach)))
		try await remember(mira.injected, using: coach)
		let remembered = try MemoryProbe.athleteData(
			in: MemoryProbe.systemText(in: try await ask(coach)))
		try await seed(
			fixture.store,
			[
				storedRecord(
					device: fixture.store.deviceId, wall: 100, ulid: fixedUlid(100),
					account: fixture.accountA, body: try SavedPlanRows.body(PlanDocumentTests.base))
			])
		let saved = try MemoryProbe.athleteData(
			in: MemoryProbe.systemText(in: try await ask(coach)))

		#expect(empty == "\n" + noPlan + "\n")
		#expect(remembered.contains(mira.goals))
		#expect(remembered.hasSuffix("\n\n" + noPlan + "\n"))
		#expect(saved.contains(mira.goals))
		#expect(
			saved.hasSuffix(
				"\n\n## Current Plan\n- Name: Base\n- Goal: century\n- Duration: 12 weeks\n"))
		#expect(!saved.contains(noPlan))
		await coach.lifecycle(.willTerminate)
	}

	@Test func rememberedTextSitsInsideTheAthleteDataFenceAfterTheCacheBoundary() async throws {
		let coach = await fixture.open()
		let empty = try MemoryProbe.systemText(in: try await ask(coach))
		try await remember(mira.injected, using: coach)
		let forMira = try MemoryProbe.systemText(in: try await ask(coach))
		try await fixture.connect(bo.key, using: coach)
		try await remember(bo.injected, using: coach)
		let forBo = try MemoryProbe.systemText(in: try await ask(coach))

		let knowledge = PromptAssembly.cyclingPrefix()
		#expect(knowledge.contains("# Domain Knowledge"))
		#expect(knowledge.hasSuffix(PromptAssembly.cacheBoundary))
		for (system, athlete) in [(forMira, mira), (forBo, bo)] {
			#expect(system.hasPrefix(knowledge))
			#expect(system.components(separatedBy: PromptAssembly.cacheBoundary).count == 2)
			let volatile = String(system.dropFirst(knowledge.count))
			let context = try MemoryProbe.athleteData(in: volatile)
			for (_, fact) in athlete.injected {
				#expect(context.contains(fact))
				#expect(system.components(separatedBy: fact).count == 2)
			}
		}
		#expect(empty.hasPrefix(knowledge))
		await coach.lifecycle(.willTerminate)
	}

	private func remember(_ facts: [(SectionName, String)], using coach: Coach) async throws {
		try await MemoryProbe.save(
			facts.map { section, content in
				.object([
					"type": .string("memory"), "section": .string(section.rawValue),
					"content": .string(content),
				])
			}, saying: "Remember this about me.", using: coach, transport: fixture.transport)
	}

	private func ask(_ coach: Coach) async throws -> CompletionRequest {
		fixture.transport.respond = ScriptedReply.sequence(
			[.text("Ride easy today."), .finish(reason: .stop)],
			otherwise: { _ in ScriptedReply([.finish(reason: .stop)]) })
		#expect(
			replyText(try await coach.sendAndSettle("What should I ride this week?"))
				== "Ride easy today.")
		return try #require(sent(.chatAttempt, by: fixture.transport).last)
	}

	private func readMemory(_ coach: Coach) async throws -> CompletionRequest {
		try await MemoryProbe.turn(
			[.toolCall(name: "memory_read", arguments: "{}")],
			saying: "What do you know about my bike?", expecting: "Here is your setup.",
			using: coach, transport: fixture.transport)
	}

	private func goalChanges() async throws -> [[String: JSONValue]] {
		try await fixture.store.fetch(RecordQuery(scope: .synced([.journal]))).records
			.compactMap { record -> [String: JSONValue]? in
				guard case .synced(.journal(let body)) = record.body else { return nil }
				let change = try JSONValue.parse(body.preview).objectFields
				return change["section"] == .string(SectionName.goals.rawValue) ? change : nil
			}
	}
}
