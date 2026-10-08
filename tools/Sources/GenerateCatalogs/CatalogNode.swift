import ToolSupport

struct CatalogFailure: Error, CustomStringConvertible {
	let description: String
}

struct CatalogMember {
	let key: String
	let value: CatalogNode
}

enum CatalogNode {
	case text(String)
	case group([CatalogMember])

	static func read(_ text: String) throws -> CatalogNode {
		do {
			return try CatalogNode(JSONValue.parse(text, as: .textTree))
		} catch let failure as JSONSyntaxFailure {
			let characters = text.utf8.prefix(failure.byte).count { $0 & 0xC0 != 0x80 }
			throw CatalogFailure(description: "Invalid catalog JSON at character \(characters)")
		}
	}

	private init(_ value: JSONValue) throws {
		switch value {
		case .string(let text):
			self = .text(text)
		case .object(let members):
			self = .group(
				try members.map { CatalogMember(key: $0.key, value: try CatalogNode($0.value)) })
		default:
			throw CatalogFailure(description: "A catalog holds only text and groups")
		}
	}
}
