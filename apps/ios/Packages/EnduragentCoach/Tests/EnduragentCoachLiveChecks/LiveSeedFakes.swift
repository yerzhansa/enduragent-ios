import EnduragentCoachFixtures
import Foundation

@testable import EnduragentCoach

actor FakeSeedAccount: SeedAccount {
	private(set) var listed: [SeedListing]
	private(set) var days: [CivilDate: [String: Double]]
	private(set) var uploads: [String] = []
	private(set) var lookups: [String] = []
	private(set) var deleted: [String] = []
	private(set) var ratings: [String] = []
	private(set) var wellnessWrites: [[CivilDate: [String: Double?]]] = []
	private var listedFromSecondRead: [SeedListing]
	private let athlete: String
	private let processes: Bool
	private let nullClears: Bool

	init(
		athlete: String = "i1001", listed: [SeedListing] = [],
		listedFromSecondRead: [SeedListing] = [], days: [CivilDate: [String: Double]] = [:],
		processes: Bool = true, nullClears: Bool = true
	) {
		self.athlete = athlete
		self.listed = listed
		self.listedFromSecondRead = listedFromSecondRead
		self.days = days
		self.processes = processes
		self.nullClears = nullClears
	}

	func athleteID() -> String { athlete }

	func activities(oldest: CivilDate, newest: CivilDate) -> [SeedListing] {
		defer {
			listed += listedFromSecondRead
			listedFromSecondRead = []
		}
		return listed
	}

	func wellness(oldest: CivilDate, newest: CivilDate) -> [CivilDate: [String: Double]] { days }

	func upload(_ activity: SeedActivity, file: Data) -> String {
		let id = "i\(900 + uploads.count)"
		uploads.append(activity.externalID)
		listed.append(
			SeedListing(
				id: id, name: activity.name, externalID: activity.externalID,
				start: activity.start.date.rawValue, load: processes ? 50 : nil))
		return id
	}

	func activityExists(_ id: String) -> Bool {
		lookups.append(id)
		return (listed + listedFromSecondRead).contains { $0.id == id }
	}

	func rate(_ id: String, feel: Int, rpe: Int) {
		ratings.append(id)
		listed = listed.map { row in
			guard row.id == id else { return row }
			var rated = row
			rated.feel = feel
			rated.rpe = rpe
			return rated
		}
	}

	func delete(_ id: String) {
		deleted.append(id)
		listed.removeAll { $0.id == id }
	}

	func writeWellness(_ written: [CivilDate: [String: Double?]]) {
		wellnessWrites.append(written)
		for (date, values) in written {
			for (field, value) in values where value != nil || nullClears {
				days[date, default: [:]][field] = value
			}
		}
	}
}

final class TCXReading: NSObject, XMLParserDelegate {
	struct Point {
		var time = ""
		var distance = 0.0
		var heartRate: Double?
		var cadence: Double?
		var watts: Double?
	}

	struct Lap {
		var seconds = 0.0
		var distance = 0.0
		var averageWatts: Double?
		var points: [Point] = []
	}

	private(set) var sport = ""
	private(set) var id = ""
	private(set) var laps: [Lap] = []
	private var path: [String] = []
	private var text = ""

	static func read(_ document: String) throws -> TCXReading {
		let reading = TCXReading()
		let parser = XMLParser(data: Data(document.utf8))
		parser.delegate = reading
		guard parser.parse() else {
			throw LiveCheckStop(
				description: "The TCX did not parse: \(String(describing: parser.parserError))")
		}
		return reading
	}

	func parser(
		_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
		qualifiedName: String?, attributes: [String: String] = [:]
	) {
		path.append(elementName)
		text = ""
		switch elementName {
		case "Activity": sport = attributes["Sport"] ?? ""
		case "Lap": laps.append(Lap())
		case "Trackpoint": laps[laps.count - 1].points.append(Point())
		default: break
		}
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		text += string
	}

	func parser(
		_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
		qualifiedName: String?
	) {
		let parent = path.dropLast().last ?? ""
		let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
		let lap = laps.count - 1
		let point = lap >= 0 ? laps[lap].points.count - 1 : -1
		switch (parent, elementName) {
		case ("Activity", "Id"): id = text
		case ("Lap", "TotalTimeSeconds"): laps[lap].seconds = number ?? -1
		case ("Lap", "DistanceMeters"): laps[lap].distance = number ?? -1
		case ("ns3:LX", "ns3:AvgWatts"): laps[lap].averageWatts = number
		case ("Trackpoint", "Time"): laps[lap].points[point].time = text
		case ("Trackpoint", "DistanceMeters"): laps[lap].points[point].distance = number ?? -1
		case ("Trackpoint", "Cadence"): laps[lap].points[point].cadence = number
		case ("HeartRateBpm", "Value") where path.dropLast(2).last == "Trackpoint":
			laps[lap].points[point].heartRate = number
		case ("ns3:TPX", "ns3:Watts"): laps[lap].points[point].watts = number
		default: break
		}
		path.removeLast()
	}
}

func temporarySeedLedger() throws -> LiveSeedLedger {
	try LiveSeedLedger(file: TestTemporaryFolders.make().appending(path: "ledger.tsv"))
}

func instantPolling(attempts: Int = 3, slept: SleepCount = SleepCount()) -> SeedPolling {
	SeedPolling(attempts: attempts, interval: .seconds(5), sleep: { _ in await slept.add() })
}

actor SleepCount {
	private(set) var count = 0

	func add() {
		count += 1
	}
}
