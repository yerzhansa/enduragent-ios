import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct PlanToolSchemaTests {
	static let draftShape = ["phases", "zoneTables"]

	let transport = FakeModelTransport()

	@Test func everyPlanToolSchemaEqualsNpmsAndPlanSaveAddsOnlyTheDraftsPhasesAndZoneTables()
		async throws
	{
		let phone = try await offeredPlanTools()

		var compared: [String] = []
		for item in try PlanFixtures.cases("tool-schemas") {
			let npm = try #require(item.output?.objectFields)
			let name = try #require(npm["name"]?.stringValue)
			let schema = try #require(phone[name], "\(name)")
			compared.append(name)
			let parameters = try #require(npm["parameters"])
			if name == ToolName.planSave.rawValue {
				let added = try #require(planProperties(of: schema.parameters))
				#expect(Self.draftShape.allSatisfy { added[$0] != nil })
				#expect(withoutDraftShape(schema.parameters) == stripped(parameters))
			} else {
				#expect(schema.parameters == stripped(parameters), "\(name)")
			}
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

	@Test func planSaveTypesEveryKeyAnNpmDraftWritesIntoAPhaseOrAZoneTable() async throws {
		let phone = try await offeredPlanTools()
		let save = try #require(phone[ToolName.planSave.rawValue])
		let properties = try #require(planProperties(of: save.parameters))
		let files = try PlanFixtures.planDraftFiles()

		var compared = 0
		var untyped: Set<String> = []
		for file in files {
			for item in try PlanFixtures.cases(file) {
				compared += 1
				let draft = try #require(item.output?.objectFields, "\(item.id)")
				for key in Self.draftShape {
					let value = try #require(draft[key], "\(item.id) \(key)")
					let schema = try #require(properties[key], "\(key)")
					untyped.formUnion(Self.untyped(value, by: schema, at: key))
				}
			}
		}

		#expect(untyped.isEmpty, "\(untyped.sorted())")
		#expect(compared == (try PlanFixtures.manifestCount(files)))
		#expect(compared > 0)
	}

	private func offeredPlanTools() async throws
		-> [String: (description: String, parameters: JSONValue)]
	{
		transport.respond = ScriptedReply.sequence(
			[.text("Easy spin today."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: InMemoryRecordLog())
		_ = try await coach.sendAndSettle("What should I ride?")
		let offered = try #require(transport.requests.first).tools
		return Dictionary(
			uniqueKeysWithValues: offered.filter {
				[.assessFeasibility, .buildPlanSkeleton, .getSampleWeek, .planSave, .planLoad]
					.contains($0.name)
			}
			.map { ($0.name.rawValue, (description: $0.description, parameters: $0.parameters)) })
	}

	private func planProperties(of schema: JSONValue) -> [String: JSONValue]? {
		schema.objectFields["properties"]?.objectFields["plan"]?.objectFields["properties"]?
			.objectFields
	}

	private func withoutDraftShape(_ schema: JSONValue) -> JSONValue {
		var fields = schema.objectFields
		var properties = fields["properties"]?.objectFields ?? [:]
		var plan = properties["plan"]?.objectFields ?? [:]
		plan["properties"] = .object(
			(plan["properties"]?.objectFields ?? [:]).filter { !Self.draftShape.contains($0.key) })
		properties["plan"] = .object(plan)
		fields["properties"] = .object(properties)
		return .object(fields)
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

	private static func untyped(_ value: JSONValue, by schema: JSONValue, at path: String)
		-> [String]
	{
		let fields = schema.objectFields
		let type = fields["type"]?.stringValue
		switch value {
		case .object(let members):
			guard type == "object" else { return [path] }
			let properties = fields["properties"]?.objectFields ?? [:]
			return members.flatMap { key, member in
				properties[key].map { untyped(member, by: $0, at: "\(path).\(key)") }
					?? ["\(path).\(key)"]
			}
		case .array(let items):
			guard type == "array", let itemSchema = fields["items"] else { return [path] }
			return items.flatMap { untyped($0, by: itemSchema, at: path) }
		case .string:
			return type == "string" ? [] : [path]
		case .number(let number):
			return type == "number" || (type == "integer" && number.rounded() == number)
				? [] : [path]
		case .bool:
			return type == "boolean" ? [] : [path]
		case .null:
			return [path]
		}
	}
}
