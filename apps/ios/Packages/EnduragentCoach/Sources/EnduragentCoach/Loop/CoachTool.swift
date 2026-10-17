import Foundation

package struct TurnReach: Sendable {
	package let training: TrainingConnection
	package let memory: MemoryView
	package let chat: ChatID
	package let ledger: Ledger
	package let clock: any Clock
	package let desk: WorkoutReviewDesk
	package let attempt: DraftKey

	package init(
		training: TrainingConnection, memory: MemoryView, chat: ChatID, ledger: Ledger,
		clock: any Clock, desk: WorkoutReviewDesk, attempt: DraftKey
	) {
		self.training = training
		self.memory = memory
		self.chat = chat
		self.ledger = ledger
		self.clock = clock
		self.desk = desk
		self.attempt = attempt
	}
}

struct LocalReach: Sendable {
	let chat: ChatID
	let scope: TurnScope
	let ledger: Ledger
	let clock: any Clock
	let desk: WorkoutReviewDesk
	let attempt: DraftKey

	fileprivate init(_ turn: TurnReach, scope: TurnScope) {
		self.chat = turn.chat
		self.scope = scope
		self.ledger = turn.ledger
		self.clock = turn.clock
		self.desk = turn.desk
		self.attempt = turn.attempt
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

enum ToolEffect: Sendable, Equatable {
	case read(ReadToolName)
	case memoryRead(MemoryReadToolName)
	case write(ReplayUnsafeToolName)
	case preparation(PreparationToolName)

	var name: ToolName {
		switch self {
		case .read(let name): name.toolName
		case .memoryRead(let name): name.toolName
		case .write(let name): name.toolName
		case .preparation(let name): name.toolName
		}
	}
}

struct BoundTool: Sendable {
	let schema: ToolSchema
	let effect: ToolEffect
	let narrowing: String?
	let run: BoundToolRun

	var name: ToolName { schema.name }
}

struct CoachTool: Sendable {
	typealias Run<Reach> = @Sendable (JSONValue, Reach) async throws -> ToolExecution
	typealias Describe = @Sendable (MemoryView) -> (description: String, parameters: JSONValue)

	let effect: ToolEffect
	private let bind: @Sendable (TurnReach) -> BoundTool?

	static func local(
		_ effect: ToolEffect, rerunWith narrowing: String?, describe: @escaping Describe,
		run: @escaping Run<LocalReach>
	) -> CoachTool {
		CoachTool(effect: effect) { turn in
			let told = describe(turn.memory)
			return BoundTool(
				schema: ToolSchema(
					name: effect.name, description: told.description, parameters: told.parameters),
				effect: effect, narrowing: narrowing
			) { arguments, scope in
				try await run(arguments, LocalReach(turn, scope: scope))
			}
		}
	}

	static func local(
		_ effect: ToolEffect, _ description: String, parameters: JSONValue,
		rerunWith narrowing: String?, run: @escaping Run<LocalReach>
	) -> CoachTool {
		local(effect, rerunWith: narrowing, describe: { _ in (description, parameters) }, run: run)
	}

	static func hiddenMemory(
		_ name: MemoryReadToolName, _ description: String, parameters: JSONValue,
		rerunWith narrowing: String?, run: @escaping Run<LocalReach>
	) -> CoachTool {
		let always = local(
			.memoryRead(name), description, parameters: parameters, rerunWith: narrowing, run: run)
		return CoachTool(effect: always.effect) { turn in
			turn.memory.hidesStoredContent ? always.bound(to: turn) : nil
		}
	}

	static func training(
		_ effect: ToolEffect, _ description: String, parameters: JSONValue,
		rerunWith narrowing: String?, run: @escaping Run<TrainingReach>
	) -> CoachTool {
		let schema = ToolSchema(
			name: effect.name, description: description, parameters: parameters)
		return CoachTool(effect: effect) { turn in
			guard case .connected(let training) = turn.training else { return nil }
			return BoundTool(schema: schema, effect: effect, narrowing: narrowing) {
				arguments, scope in
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

enum CoachTools {
	static let memoryReads = Set(
		ToolName.allCases.filter { name in
			guard case .memoryRead? = definition(of: name)?.effect else { return false }
			return true
		})

	static func definition(of name: ToolName) -> CoachTool? {
		switch name {
		case .calculateZones: calculateZones
		case .intervalsFetchAthlete: fetchAthlete
		case .intervalsFetchWellness: fetchWellness
		case .intervalsFetchActivity: fetchActivity
		case .intervalsFetchStreams: fetchStreams
		case .intervalsFetchActivities: fetchActivities
		case .intervalsListEvents: listEvents
		case .getPendingWorkoutChanges: getPendingWorkoutChanges
		case .prepareWorkoutChanges: prepareWorkoutChanges
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
		bound = ToolName.allCases.compactMap(CoachTools.definition(of:))
			.compactMap { $0.bound(to: turn) }
	}

	package var schemas: [ToolSchema] {
		bound.map(\.schema)
	}

	func tool(named name: String) -> BoundTool? {
		bound.first { $0.name.rawValue == name }
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
