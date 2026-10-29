import Foundation

package struct UsageLine: Sendable, Equatable, Codable {
	package let origin: UsageOrigin
	package let model: ModelRef
	package let calls: Int
	package let failedCalls: Int
	package let inputTokens: Int
	package let outputTokens: Int
	package let cost: UsageCost
	package let durationMilliseconds: Int

	private enum Key: String, CodingKey {
		case origin
		case turn
		case attempt
		case ending
		case model
		case calls
		case failedCalls
		case inputTokens
		case outputTokens
		case cost
		case durationMilliseconds
	}

	private enum OriginName: String, Codable {
		case turn
		case memorySave
	}

	package init(
		origin: UsageOrigin, model: ModelRef, calls: Int, failedCalls: Int, inputTokens: Int,
		outputTokens: Int, cost: UsageCost, durationMilliseconds: Int
	) {
		self.origin = origin
		self.model = model
		self.calls = calls
		self.failedCalls = failedCalls
		self.inputTokens = inputTokens
		self.outputTokens = outputTokens
		self.cost = cost
		self.durationMilliseconds = durationMilliseconds
	}

	package init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: Key.self)
		switch try container.decode(OriginName.self, forKey: .origin) {
		case .turn:
			origin = .turn(
				turn: try container.decodeULID(forKey: .turn),
				attempt: try container.decodeULID(forKey: .attempt),
				ending: try container.decode(TurnUsageEnding.self, forKey: .ending))
		case .memorySave:
			origin = .memorySave(
				attempt: try container.decodeULID(forKey: .attempt),
				ending: try container.decode(MemorySaveEnding.self, forKey: .ending))
		}
		model = try container.decode(ModelRef.self, forKey: .model)
		calls = try container.decode(Int.self, forKey: .calls)
		failedCalls = try container.decode(Int.self, forKey: .failedCalls)
		inputTokens = try container.decode(Int.self, forKey: .inputTokens)
		outputTokens = try container.decode(Int.self, forKey: .outputTokens)
		cost = try container.decode(UsageCost.self, forKey: .cost)
		durationMilliseconds = try container.decode(Int.self, forKey: .durationMilliseconds)
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		switch origin {
		case .turn(let turn, let attempt, let ending):
			try container.encode(OriginName.turn, forKey: .origin)
			try container.encode(turn.rawValue, forKey: .turn)
			try container.encode(attempt.rawValue, forKey: .attempt)
			try container.encode(ending, forKey: .ending)
		case .memorySave(let attempt, let ending):
			try container.encode(OriginName.memorySave, forKey: .origin)
			try container.encode(attempt.rawValue, forKey: .attempt)
			try container.encode(ending, forKey: .ending)
		}
		try container.encode(model, forKey: .model)
		try container.encode(calls, forKey: .calls)
		try container.encode(failedCalls, forKey: .failedCalls)
		try container.encode(inputTokens, forKey: .inputTokens)
		try container.encode(outputTokens, forKey: .outputTokens)
		try container.encode(cost, forKey: .cost)
		try container.encode(durationMilliseconds, forKey: .durationMilliseconds)
	}
}

package enum UsageOrigin: Sendable, Equatable {
	case turn(turn: ULID, attempt: ULID, ending: TurnUsageEnding)
	case memorySave(attempt: ULID, ending: MemorySaveEnding)
}

package enum TurnUsageEnding: String, Sendable, Codable {
	case replied
	case savedWork
	case failed
	case interrupted

	package init(_ settlement: Settlement) {
		switch settlement {
		case .replied: self = .replied
		case .savedWork: self = .savedWork
		case .failed: self = .failed
		case .interrupted: self = .interrupted
		}
	}
}

package enum MemorySaveEnding: String, Sendable, Codable {
	case saved
	case nothingToSave
	case partial
	case failed

	package init(_ ending: FlushEnding) {
		switch ending {
		case .saved: self = .saved
		case .nothingToSave: self = .nothingToSave
		case .partial: self = .partial
		case .failed: self = .failed
		}
	}
}

package enum UsageCost: Sendable, Equatable, Codable {
	case reported(Double)
	case unreported

	package init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		self = container.decodeNil() ? .unreported : .reported(try container.decode(Double.self))
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .reported(let cost): try container.encode(cost)
		case .unreported: try container.encodeNil()
		}
	}
}

package struct ModelRef: Sendable, Equatable, Codable {
	package let rawValue: String

	package init?(_ model: ModelID) {
		guard Self.isRef(model.rawValue) else { return nil }
		rawValue = model.rawValue
	}

	package init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		let raw = try container.decode(String.self)
		guard Self.isRef(raw) else {
			throw DecodingError.dataCorruptedError(
				in: container, debugDescription: "The value is not a model id.")
		}
		rawValue = raw
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}

	private static func isRef(_ raw: String) -> Bool {
		(1...128).contains(raw.unicodeScalars.count)
			&& raw.unicodeScalars.allSatisfy {
				("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
					|| "._:/@-".unicodeScalars.contains($0)
			}
	}
}
