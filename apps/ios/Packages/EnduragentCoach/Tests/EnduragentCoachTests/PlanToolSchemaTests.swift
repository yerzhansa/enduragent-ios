import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct PlanToolSchemaTests {
	let transport = FakeModelTransport()

	@Test func everyPlanToolSchemaEqualsNpmsAfterTheTwoRecordedStrips() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Easy spin today."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: InMemoryRecordLog())
		_ = try await coach.sendAndSettle("What should I ride?")
		let offered = try #require(transport.requests.first).tools
		let phone = Dictionary(
			uniqueKeysWithValues: offered.filter {
				[.assessFeasibility, .buildPlanSkeleton, .getSampleWeek, .planSave, .planLoad]
					.contains($0.name)
			}
			.map { ($0.name.rawValue, (description: $0.description, parameters: $0.parameters)) })

		var compared: [String] = []
		for item in try PlanFixtures.cases("tool-schemas") {
			let npm = try #require(item.output?.objectFields)
			let name = try #require(npm["name"]?.stringValue)
			let schema = try #require(phone[name], "\(name)")
			compared.append(name)
			let parameters = try #require(npm["parameters"])
			#expect(schema.parameters == stripped(parameters), "\(name)")
			#expect(.string(schema.description) == npm["description"], "\(name)")
		}

		#expect(
			compared.sorted() == [
				"assess_feasibility", "build_plan_skeleton", "get_sample_week", "plan_load",
				"plan_save",
			])
		#expect(compared.count == (try PlanFixtures.manifestCount(["tool-schemas"])))
		#expect(compared.count > 0)
	}

	private func stripped(_ schema: JSONValue) -> JSONValue {
		switch schema {
		case .object(let fields):
			.object(
				fields.filter { $0.key != "$schema" && $0.key != "additionalProperties" }
					.mapValues(stripped))
		case .array(let items):
			.array(items.map(stripped))
		case .null, .bool, .number, .string:
			schema
		}
	}
}
