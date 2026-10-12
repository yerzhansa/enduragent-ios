import Foundation

struct CalendarEventPayload: Decodable {
	let id: Int
	let start: String
	let name: String
	let category: String
	let externalID: String?
	let uid: String?
	let tags: [String]?
	let description: String?
	let type: String?

	private enum CodingKeys: String, CodingKey {
		case id, name, category, uid, tags, description, type
		case start = "start_date_local"
		case externalID = "external_id"
	}
}
