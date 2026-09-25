import Foundation

public enum DisplayZones {
	public static func calculate(ftpWatts: Int) throws -> [String] {
		try table(ftpWatts: ftpWatts).map(\.value)
	}

	package struct Row: Sendable, Equatable {
		package var label: String
		package var value: String
		package var overlaps: Bool
	}

	package static func table(ftpWatts: Int) throws -> [Row] {
		guard IntervalsPolicy.ftpRange.contains(ftpWatts) else {
			throw IntervalsError(
				code: "invalid_ftp",
				details: "FTP must be between 50 and 600 watts."
			)
		}
		func band(_ fraction: Double) -> Int {
			Int((Double(ftpWatts) * fraction).rounded())
		}
		return [
			Row(label: "Z1 Active Recovery", value: "< \(band(0.55))W", overlaps: false),
			Row(label: "Z2 Endurance", value: "\(band(0.56))-\(band(0.75))W", overlaps: false),
			Row(label: "Z3 Tempo", value: "\(band(0.76))-\(band(0.9))W", overlaps: false),
			Row(
				label: "Sweet Spot (88-94%)", value: "\(band(0.88))-\(band(0.94))W", overlaps: true),
			Row(label: "Z4 Threshold", value: "\(band(0.91))-\(band(1.05))W", overlaps: false),
			Row(label: "Z5 VO2max", value: "\(band(1.06))-\(band(1.2))W", overlaps: false),
		]
	}

	package static func json(ftpWatts: [Int]) throws -> JSONValue {
		var object: [String: JSONValue] = [:]
		for ftp in ftpWatts {
			object[String(ftp)] = .array(
				try table(ftpWatts: ftp).map { row in
					var fields: [String: JSONValue] = [
						"label": .string(row.label),
						"value": .string(row.value),
					]
					if row.overlaps {
						fields["overlaps"] = .bool(true)
					}
					return .object(fields)
				})
		}
		return .object(object)
	}
}
