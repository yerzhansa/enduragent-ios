import Foundation

public struct ActivityID: Hashable, Sendable {
	public let rawValue: String

	public init?(rawValue: String) {
		let digits = Self.isDigits(rawValue[...])
		let prefixed = rawValue.first == "i" && Self.isDigits(rawValue.dropFirst())
		let hex = rawValue.count == 64 && rawValue.allSatisfy { $0.isHexDigit && !$0.isUppercase }
		guard digits || prefixed || hex else { return nil }
		self.rawValue = rawValue
	}

	private static func isDigits(_ text: Substring) -> Bool {
		!text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
	}
}

public struct EventID: Hashable, Sendable {
	public let rawValue: Int
	public init(rawValue: Int) { self.rawValue = rawValue }
}

public struct ChatExternalID: Hashable, Sendable {
	public var date: CivilDate
	public var slug: String

	public var rawValue: String {
		"cycling-coach:\(date):\(slug)"
	}

	public static func slugify(name: String) -> String {
		var characters: [Character] = []
		var pendingDash = false
		for character in name.lowercased() {
			guard let ascii = character.asciiValue else {
				pendingDash = true
				continue
			}
			let isDigit = ascii >= 48 && ascii <= 57
			let isLetter = ascii >= 97 && ascii <= 122
			if isDigit || isLetter {
				if pendingDash, !characters.isEmpty {
					characters.append("-")
				}
				characters.append(character)
				pendingDash = false
			} else {
				pendingDash = true
			}
		}
		var slug = String(characters)
		if slug.count > 40 {
			slug = String(slug.prefix(40))
			while slug.hasSuffix("-") {
				slug.removeLast()
			}
		}
		return slug.isEmpty ? "workout" : slug
	}
}

public struct CalendarEvent: Sendable, Equatable {
	package var description: String? = nil
	package var type: String? = nil
	package var movingTime: Int?
	package var trainingLoad: Int?
	package var workoutDocument: JSONValue?
	public var id: EventID
	public var startDateLocal: String
	public var name: String?
	public var category: String
	public var externalId: String?
	public var uid: String?
	public var tags: [String]
	public var coachCreated: Bool

	package init(
		description: String? = nil, type: String? = nil,
		id: EventID, startDateLocal: String, name: String?, category: String, externalId: String?,
		uid: String?, tags: [String], coachCreated: Bool,
		movingTime: Int? = nil, trainingLoad: Int? = nil, workoutDocument: JSONValue? = nil
	) {
		self.description = description
		self.type = type
		self.movingTime = movingTime
		self.trainingLoad = trainingLoad
		self.workoutDocument = workoutDocument
		self.id = id
		self.startDateLocal = startDateLocal
		self.name = name
		self.category = category
		self.externalId = externalId
		self.uid = uid
		self.tags = tags
		self.coachCreated = coachCreated
	}
}

public enum CalendarEventType: String, Sendable {
	case ride = "Ride"
	case weightTraining = "WeightTraining"
}

package protocol IntervalsClient: Sendable {
	func fetchEvent(id: EventID) async throws -> CalendarEvent
	func listEvents(in range: ReadRange) async throws -> [CalendarEvent]
	func write(_ write: CalendarWrite) async -> IntervalsWriteAnswer
}

package enum CalendarWrite: Sendable, Equatable {
	case create(CalendarPayload, identity: CalendarWriteID)
	case update(EventID, WorkoutPatch)
	case delete(EventID)
}

public enum IntervalsWriteAnswer: Sendable, Equatable {
	case saved(CalendarEvent?)
	case httpStatus(Int)
	case lost(ClientLoss)
}

public enum ClientLoss: Sendable, Equatable {
	case transport
	case unreadableBody
	case canceled
}

public struct IntervalsError: Error, Sendable, Equatable {
	public var code: String
	public var details: String
	public var status: Int?

	public init(code: String, details: String, status: Int? = nil) {
		self.code = code
		self.details = details
		self.status = status
	}

	package var json: JSONValue {
		var fields: [String: JSONValue] = [
			"error": .string(code),
			"details": .string(details),
		]
		if let status {
			fields["status"] = .number(Double(status))
		}
		return .object(fields)
	}

	package static func unreachable(_ error: URLError) -> IntervalsError {
		IntervalsError(
			code: "network",
			details: "intervals.icu could not be reached (URLError \(error.code.rawValue)).")
	}
}

package enum IntervalsPolicy {
	package static let listMaxRangeDays = 366
	package static let athletePath = "0"
	package static let baseURL: URL = {
		guard let url = URL(string: "https://intervals.icu/api/v1") else {
			fatalError("https://intervals.icu/api/v1 is invalid")
		}
		return url
	}()
	package static let coachTag = "cycling-coach"
	package static let stravaSource = "STRAVA"
	package static let ftpRange = 50...600
	package static let cyclingSports: Set<String> = [
		"Ride", "VirtualRide", "MountainBikeRide", "GravelRide", "EBikeRide",
	]
	package static let requestTimeout: TimeInterval = 30
	package static let streamRequestLimit = 3

	package static func today(now: Date, timeZone: TimeZone) -> CivilDate {
		CivilDate(date: now, timeZone: timeZone)
	}

	package static func inclusiveDayCount(from oldest: CivilDate, to newest: CivilDate) -> Int {
		if oldest > newest { return 0 }
		return gregorianDayNumber(newest) - gregorianDayNumber(oldest) + 1
	}

	private static func gregorianDayNumber(_ date: CivilDate) -> Int {
		let key = DateKey.from(date).rawValue
		let year = key / 10_000
		let month = key / 100 % 100
		let day = key % 100
		let previousYear = year - 1
		let daysBeforeMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
		let leapDay = month > 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 1 : 0
		return previousYear * 365 + previousYear / 4 - previousYear / 100 + previousYear / 400
			+ daysBeforeMonth[month - 1] + leapDay + day
	}

	package static func isCoachOwned(externalId: String?, tags: [String]) -> Bool {
		if tags.contains(coachTag) { return true }
		if let externalId, externalId.hasPrefix("\(coachTag):") { return true }
		return false
	}

	package static func rejectPastCreationDate(_ date: CivilDate, today: CivilDate)
		throws(ToolInputError)
	{
		if date < today {
			throw ToolInputError(
				code: "past_date_refused",
				details:
					"Cannot create a workout dated \(date.rawValue) — it's before today (\(today.rawValue)). Use today's date or later."
			)
		}
	}

	package static func refuseMutableEvent(
		_ event: CalendarEvent,
		today: CivilDate,
		eventId: EventID,
		action: String,
		nextDate: CivilDate?
	) throws {
		let verb = action == "delete" ? "deleted" : "updated"
		if event.category != "WORKOUT" {
			throw IntervalsError(
				code: "not_a_workout",
				details:
					"Event \(eventId.rawValue) is category \(event.category.isEmpty ? "unknown" : event.category), not a scheduled workout. Races, notes, plans, and other calendar entries cannot be \(verb) by the coach."
			)
		}
		if !isCoachOwned(externalId: event.externalId, tags: event.tags) {
			let athleteAction = action == "delete" ? "remove" : "change"
			throw IntervalsError(
				code: "not_coach_created",
				details:
					"This workout was not created by this coach (no provenance marker) — it may be athlete-added, from another app, or created before provenance markers shipped. It will not be \(verb); the athlete can \(athleteAction) it directly on intervals.icu."
			)
		}
		let eventDate = String(event.startDateLocal.prefix(10))
		if eventDate < today.rawValue {
			throw IntervalsError(
				code: "past_workout_protected",
				details:
					"Cannot \(action) workout dated \(eventDate) — it's before today (\(today.rawValue))."
			)
		}
		if let nextDate, nextDate.rawValue < today.rawValue {
			throw IntervalsError(
				code: "past_workout_destination",
				details:
					"Cannot move workout to \(nextDate.rawValue) — it's before today (\(today.rawValue))."
			)
		}
	}
}
