import Foundation

package struct TurnReach: Sendable {
	package let training: TrainingConnection
	package let memory: MemoryView
	package let chat: ChatID
	package let ledger: Ledger
	package let clock: any Clock
	package let reviews: SingleProposalReviews

	package init(
		training: TrainingConnection, memory: MemoryView, chat: ChatID, ledger: Ledger,
		clock: any Clock, reviews: SingleProposalReviews
	) {
		self.training = training
		self.memory = memory
		self.chat = chat
		self.ledger = ledger
		self.clock = clock
		self.reviews = reviews
	}
}

struct LocalReach: Sendable {
	let chat: ChatID
	let scope: TurnScope
	let ledger: Ledger
	let clock: any Clock
	let reviews: SingleProposalReviews

	fileprivate init(_ turn: TurnReach, scope: TurnScope) {
		self.chat = turn.chat
		self.scope = scope
		self.ledger = turn.ledger
		self.clock = turn.clock
		self.reviews = turn.reviews
	}

	var today: CivilDate {
		IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
	}
}

struct TrainingReach: Sendable {
	let local: LocalReach
	let training: ConnectedTraining

	var reads: any TrainingReads { training.client }
	var calendar: any IntervalsClient { training.client }
}

typealias BoundToolRun = @Sendable (JSONValue, TurnScope) async throws -> ToolExecution

struct BoundTool: Sendable {
	let schema: ToolSchema
	let run: BoundToolRun
}

struct CoachTool: Sendable {
	typealias Run<Reach> = @Sendable (JSONValue, Reach) async throws -> ToolExecution
	typealias Describe = @Sendable (MemoryView) -> (description: String, parameters: JSONValue)

	private let bind: @Sendable (TurnReach) -> BoundTool?

	static func local(
		_ name: ToolName, describe: @escaping Describe, run: @escaping Run<LocalReach>
	) -> CoachTool {
		CoachTool { turn in
			let told = describe(turn.memory)
			return BoundTool(
				schema: ToolSchema(
					name: name, description: told.description, parameters: told.parameters)
			) { arguments, scope in
				try await run(arguments, LocalReach(turn, scope: scope))
			}
		}
	}

	static func local(
		_ name: ToolName, _ description: String, parameters: JSONValue,
		run: @escaping Run<LocalReach>
	) -> CoachTool {
		local(name, describe: { _ in (description, parameters) }, run: run)
	}

	static func hiddenMemory(
		_ name: ToolName, _ description: String, parameters: JSONValue,
		run: @escaping Run<LocalReach>
	) -> CoachTool {
		let always = local(name, description, parameters: parameters, run: run)
		return CoachTool { turn in
			turn.memory.hidesStoredContent ? always.bound(to: turn) : nil
		}
	}

	static func training(
		_ name: ToolName, _ description: String, parameters: JSONValue,
		run: @escaping Run<TrainingReach>
	) -> CoachTool {
		let schema = ToolSchema(name: name, description: description, parameters: parameters)
		return CoachTool { turn in
			guard case .connected(let training) = turn.training else { return nil }
			return BoundTool(schema: schema) { arguments, scope in
				try await run(
					arguments,
					TrainingReach(local: LocalReach(turn, scope: scope), training: training))
			}
		}
	}

	func bound(to turn: TurnReach) -> BoundTool? {
		bind(turn)
	}
}

enum ToolEffect: Sendable, Equatable {
	case read
	case memoryRead
	case write(ReplayUnsafeToolName)
	case proposal(GatedToolName)
}

extension ToolName {
	var effect: ToolEffect {
		switch self {
		case .calculateZones, .intervalsFetchAthlete, .intervalsFetchWellness,
			.intervalsFetchActivity, .intervalsFetchStreams, .intervalsFetchActivities,
			.intervalsListEvents:
			.read
		case .memoryRead, .memoryQuery: .memoryRead
		case .memoryWrite: .write(.memoryWrite)
		case .ledgerAppend: .write(.ledgerAppend)
		case .intervalsCreateWorkout: .proposal(.intervalsCreateWorkout)
		case .intervalsCreateStrengthWorkout: .proposal(.intervalsCreateStrengthWorkout)
		case .intervalsDeleteWorkout: .proposal(.intervalsDeleteWorkout)
		case .intervalsUpdateWorkout: .proposal(.intervalsUpdateWorkout)
		case .planSave: .proposal(.planSave)
		}
	}
}

enum CoachTools {
	static func definition(of name: ToolName) -> CoachTool? {
		switch name {
		case .calculateZones: calculateZones
		case .intervalsFetchAthlete: fetchAthlete
		case .intervalsFetchWellness: fetchWellness
		case .intervalsFetchActivity: fetchActivity
		case .intervalsFetchStreams: fetchStreams
		case .intervalsFetchActivities: fetchActivities
		case .intervalsListEvents: listEvents
		case .intervalsCreateWorkout: createWorkout
		case .intervalsCreateStrengthWorkout: createStrengthWorkout
		case .intervalsDeleteWorkout: deleteWorkout
		case .intervalsUpdateWorkout: updateWorkout
		case .memoryRead: memoryRead
		case .memoryQuery: memoryQuery
		case .memoryWrite: memoryWrite
		case .ledgerAppend: ledgerAppend
		case .planSave: nil
		}
	}
}

package struct ToolOffer: Sendable {
	private let bound: [BoundTool]

	package init(for turn: TurnReach) {
		bound = ToolName.allCases.compactMap { CoachTools.definition(of: $0)?.bound(to: turn) }
	}

	package var schemas: [ToolSchema] {
		bound.map(\.schema)
	}

	package func offers(_ name: ToolName) -> Bool {
		tool(for: name) != nil
	}

	func tool(for name: ToolName) -> BoundTool? {
		bound.first { $0.schema.name == name }
	}
}

enum ToolParameters {
	static let none = object(properties: [:], required: [])

	static func object(properties: [String: JSONValue], required: [String]) -> JSONValue {
		var fields: [String: JSONValue] = [
			"type": .string("object"),
			"properties": .object(properties),
		]
		if !required.isEmpty {
			fields["required"] = .array(required.map { .string($0) })
		}
		return .object(fields)
	}

	static func string(_ description: String) -> JSONValue {
		.object([
			"type": .string("string"),
			"description": .string(description),
		])
	}

	static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil)
		-> JSONValue
	{
		var fields: [String: JSONValue] = [
			"type": .string("integer"),
			"description": .string(description),
		]
		if let minimum {
			fields["minimum"] = .number(Double(minimum))
		}
		if let maximum {
			fields["maximum"] = .number(Double(maximum))
		}
		return .object(fields)
	}
}
