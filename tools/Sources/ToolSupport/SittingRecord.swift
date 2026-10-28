import Foundation

public enum StepVerdict: Sendable, Equatable {
	case pass
	case fail(check: String)
	case blocked(reason: String)

	public init?(_ text: String) {
		if text == "pass" {
			self = .pass
		} else if let check = Self.detail(of: text, after: "fail ") {
			self = .fail(check: check)
		} else if let reason = Self.detail(of: text, after: "blocked ") {
			self = .blocked(reason: reason)
		} else {
			return nil
		}
	}

	public var text: String {
		switch self {
		case .pass: "pass"
		case .fail(let check): "fail \(check)"
		case .blocked(let reason): "blocked \(reason)"
		}
	}

	private static func detail(of text: String, after prefix: String) -> String? {
		guard text.hasPrefix(prefix) else { return nil }
		let detail = String(text.dropFirst(prefix.count))
		guard !detail.contains(where: \.isNewline),
			detail.contains(where: { !$0.isWhitespace })
		else { return nil }
		return detail
	}
}

public struct SittingEntry: Sendable, Equatable, Decodable {
	public let verdict: StepVerdict
	public let date: String

	private enum CodingKeys: String, CodingKey {
		case verdict, date
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let text = try container.decode(String.self, forKey: .verdict)
		guard let verdict = StepVerdict(text) else {
			throw DecodingError.dataCorruptedError(
				forKey: .verdict, in: container,
				debugDescription: "\(text) is not pass, fail <check> or blocked <reason>")
		}
		let date = try container.decode(String.self, forKey: .date)
		guard Self.isDay(date) else {
			throw DecodingError.dataCorruptedError(
				forKey: .date, in: container, debugDescription: "\(date) is not a YYYY-MM-DD day")
		}
		self.verdict = verdict
		self.date = date
	}

	private static func isDay(_ text: String) -> Bool {
		let shape = Array(text.utf8)
		return shape.count == 10
			&& shape.indices.allSatisfy { index in
				[4, 7].contains(index)
					? shape[index] == UInt8(ascii: "-")
					: (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(shape[index])
			}
	}
}

public struct SittingRecord: Sendable, Equatable, Decodable {
	public static let path = "coverage/closeout/sitting.json"

	public let steps: [String: SittingEntry]

	public static func load(root: String) throws -> SittingRecord {
		try JSONDecoder().decode(
			SittingRecord.self, from: FileSystem.read(NodePath.join(root, path)))
	}
}
