import Foundation
import Testing

@testable import EnduragentCoach

struct CarriedReviewTexts {
	static let activityTools: [ToolName] = [
		.intervalsFetchActivities, .intervalsFetchActivity, .intervalsFetchStreams,
	]

	let rules: String
	let topic: String
	let tools: [ToolSchema]

	init(system: String, tools: [ToolSchema]) throws {
		let sections = system.components(separatedBy: PromptAssembly.sectionSeparator)
		let heading = "## Skill: cycling-review\n\n"
		let skill = try #require(sections.first { $0.contains(heading) })
		rules = try #require(sections.first { $0.hasPrefix("# Workout Review") })
		topic = String(skill[try #require(skill.range(of: heading)).upperBound...])
		self.tools = tools
	}

	func schema(of tool: ToolName) throws -> ToolSchema {
		try #require(tools.first { $0.name == tool })
	}

	func description(of tool: ToolName) throws -> String {
		try schema(of: tool).description
	}

	func identifierDescription(of tool: ToolName) throws -> String {
		try #require(
			try schema(of: tool).parameters.objectFields["properties"]?
				.objectFields["activityId"]?.objectFields["description"]?.stringValue)
	}

	func tier(_ letter: String, until end: String) throws -> String {
		let flat = rules.flattened
		let start = try #require(flat.range(of: "- **Tier \(letter) "))
		let stop = try #require(flat.range(of: end, range: start.upperBound..<flat.endIndex))
		return String(flat[start.lowerBound..<stop.lowerBound])
	}

	func topicTables() -> [[[String]]] {
		var tables: [[[String]]] = []
		var open = false
		for line in topic.components(separatedBy: "\n") {
			guard line.hasPrefix("|") else {
				open = false
				continue
			}
			let cells = line.split(separator: "|").map {
				$0.trimmingCharacters(in: .whitespaces)
			}
			if !open { tables.append([]) }
			open = true
			if !cells.allSatisfy({ $0.allSatisfy { $0 == "-" } }) {
				tables[tables.count - 1].append(cells)
			}
		}
		return tables
	}

	func reviewTexts() throws -> [(name: String, text: String)] {
		[("the review rules", rules), ("the review topic", topic)]
			+ (try Self.activityTools.map {
				let schema = try schema(of: $0)
				return ($0.rawValue, schema.description + schema.parameters.canonicalDigestInput())
			})
	}

	func text(named name: String) throws -> String {
		if name == "reviewRules" { return rules }
		if name == "activityId" {
			let detail = try identifierDescription(of: .intervalsFetchActivity)
			try #require(try identifierDescription(of: .intervalsFetchStreams) == detail)
			return detail
		}
		return try description(of: try #require(ToolName(rawValue: name)))
	}
}

struct NpmReviewTexts: Decodable {
	struct Text: Decodable {
		let npm: String
		let differences: [Difference]
	}

	struct Difference: Decodable {
		let npm: String
		let phone: String
	}

	let texts: [String: Text]
}

extension String {
	var flattened: String {
		split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	func says(_ passage: String) -> Bool {
		flattened.contains(passage.flattened)
	}
}
