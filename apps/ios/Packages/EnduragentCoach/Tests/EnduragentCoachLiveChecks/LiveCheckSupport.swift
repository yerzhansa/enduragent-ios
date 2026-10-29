import Foundation

@testable import EnduragentCoach

enum LiveCheck: String, Sendable {
	case reads
	case coach
	case calendar
	case plan
	case feedback

	static let selectorVariable = "ENDURAGENT_LIVE"
	static let logsVariable = "ENDURAGENT_LIVE_LOGS"

	static var selected: LiveCheck? {
		ProcessInfo.processInfo.environment[selectorVariable].flatMap(LiveCheck.init(rawValue:))
	}

	var spend: (milestone: LiveMilestone, limit: Double)? {
		switch self {
		case .coach: (.m4, 10.0)
		case .plan: (.m5, 5.0)
		case .reads, .calendar, .feedback: nil
		}
	}
}

struct LiveCheckStop: Error, CustomStringConvertible, Sendable {
	let description: String
}

struct KeychainLookup: Sendable {
	static let itemNotFound: Int32 = 44

	let status: Int32
	let output: Data
}

enum LiveKey: String, CaseIterable, Sendable {
	case intervals = "enduragent-m3-intervals-api-key"
	case openRouter = "enduragent-m3-openrouter-key"

	var missingLine: String {
		"Missing Keychain item \(rawValue). Add it with: security add-generic-password -a \"$USER\" -s \(rawValue) -w"
	}

	func secret(from lookup: KeychainLookup) throws(LiveCheckStop) -> String {
		switch lookup.status {
		case 0:
			var secret = String(decoding: lookup.output, as: UTF8.self)
			while secret.hasSuffix("\n") { secret.removeLast() }
			guard !secret.isEmpty else { throw LiveCheckStop(description: missingLine) }
			return secret
		case KeychainLookup.itemNotFound:
			throw LiveCheckStop(description: missingLine)
		default:
			throw LiveCheckStop(
				description:
					"Reading Keychain item \(rawValue) failed: security exited with status \(lookup.status)."
			)
		}
	}

	static func secrets(
		_ keys: [LiveKey], lookUp: (LiveKey) throws -> KeychainLookup
	) throws -> [LiveKey: String] {
		var found: [LiveKey: String] = [:]
		var stops: [String] = []
		for key in keys {
			do {
				found[key] = try key.secret(from: try lookUp(key))
			} catch let stop as LiveCheckStop {
				stops.append(stop.description)
			}
		}
		guard stops.isEmpty else { throw LiveCheckStop(description: stops.joined(separator: "\n")) }
		return found
	}

	#if os(macOS)
		static func lookUpInKeychain(_ key: LiveKey) throws -> KeychainLookup {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
			process.arguments = ["find-generic-password", "-s", key.rawValue, "-w"]
			let output = Pipe()
			process.standardOutput = output
			process.standardError = FileHandle.nullDevice
			try process.run()
			let data = output.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			return KeychainLookup(status: process.terminationStatus, output: data)
		}
	#endif
}

struct LiveRunFolder: Sendable {
	let logs: URL
	let run: URL

	init(kind: LiveCheck, startedAt now: Date) throws {
		guard let logs = ProcessInfo.processInfo.environment[LiveCheck.logsVariable], !logs.isEmpty
		else {
			throw LiveCheckStop(
				description:
					"\(LiveCheck.logsVariable) is not set. Run the check through make live-\(kind.rawValue)."
			)
		}
		try self.init(
			logs: URL(fileURLWithPath: logs, isDirectory: true), kind: kind, startedAt: now)
	}

	init(logs: URL, kind: LiveCheck, startedAt now: Date) throws {
		self.logs = logs
		self.run = logs.appending(path: kind.rawValue).appending(path: Self.stamp(now))
		try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
	}

	func files(containing secret: String) throws -> [String] {
		let needle = Data(secret.utf8)
		var holding: [String] = []
		for path in try FileManager.default.subpathsOfDirectory(atPath: run.path).sorted() {
			let file = run.appending(path: path)
			guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
			else { continue }
			if try Data(contentsOf: file).range(of: needle) != nil { holding.append(path) }
		}
		return holding
	}

	static func stamp(_ date: Date) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone.current
		formatter.dateFormat = "yyyyMMdd'T'HHmmss"
		return formatter.string(from: date)
	}

	func write(_ text: String, to name: String) throws {
		try write(Data(text.utf8), to: name)
	}

	func write(_ data: Data, to name: String) throws {
		let file = run.appending(path: name)
		try FileManager.default.createDirectory(
			at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try data.write(to: file, options: .atomic)
	}

	func write(json value: JSONValue, to name: String) throws {
		try write(prettyJSON(value), to: name)
	}
}

func prettyJSON(_ value: JSONValue) throws -> Data {
	try JSONSerialization.data(
		withJSONObject: OpenRouterJSON.jsonObject(from: value),
		options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
}
