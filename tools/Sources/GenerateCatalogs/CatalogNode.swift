enum CatalogNode: Decodable {
	case text(String)
	case group([String: CatalogNode])

	init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let text = try? container.decode(String.self) {
			self = .text(text)
		} else {
			self = .group(try container.decode([String: CatalogNode].self))
		}
	}
}
