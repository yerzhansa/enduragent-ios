import Foundation
import ToolSupport

struct SimFailure: Error, CustomStringConvertible {
	let description: String
}

struct Simulator {
	static let commands = [
		"doctor", "build", "create", "install", "launch", "shot", "test", "parity", "cleanup",
	]

	let repo: URL
	let runsRoot: URL
	let captures: URL
	let deviceType: String
	let bundleId = "icu.enduragent.app"
	let project: URL
	let derivedData: URL
	let products: URL
	let appPath: URL
	let simPrefix = "enduragent-verify-"
	let fixtureArguments = [
		"-EnduragentFixture", "first-week", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
	]
	let statusBar = [
		"--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
		"--cellularMode", "active", "--cellularBars", "4", "--batteryState", "charged",
		"--batteryLevel", "100",
	]

	init(source: String = #filePath) throws {
		let sourceDirectory = URL(fileURLWithPath: source).deletingLastPathComponent().path
		let toplevel = try Shell.output(
			"git", ["-C", sourceDirectory, "rev-parse", "--show-toplevel"])
		repo = URL(fileURLWithPath: trimmed(toplevel), isDirectory: true)
		let environment = ProcessInfo.processInfo.environment
		let home = FileManager.default.homeDirectoryForCurrentUser
		runsRoot = URL(
			fileURLWithPath: environment["ENDURAGENT_VERIFY_RUNS"]
				?? home.appendingPathComponent("Library/Logs/enduragent-verify").path)
		captures = URL(
			fileURLWithPath: environment["ENDURAGENT_PROTOTYPE_CAPTURES"]
				?? home.appendingPathComponent(
					"projects/enduragent/desktop/docs/prototypes/ios/captures-2026-09-25"
				).path)
		deviceType = environment["ENDURAGENT_SIM_DEVICE"] ?? "iPhone 17e"
		project = repo.appendingPathComponent("apps/ios/Enduragent.xcodeproj")
		derivedData = repo.appendingPathComponent("DerivedData")
		products = derivedData.appendingPathComponent("Build/Products")
		appPath = products.appendingPathComponent("Debug-iphonesimulator/Enduragent.app")
	}

	func perform(_ command: String, _ arguments: [String]) throws -> Bool {
		let first = argument(arguments, 0)
		switch command {
		case "doctor":
			return try doctor(first)
		case "build":
			try build()
		case "create":
			try create(first)
		case "install":
			try install(first)
		case "launch":
			try launch(first, Array(arguments.dropFirst()))
		case "shot":
			try shot(first, argument(arguments, 1))
		case "test":
			try test(first, Array(arguments.dropFirst()))
		case "parity":
			try parity(
				first, state: argument(arguments, 1), theme: argument(arguments, 2),
				flag: argument(arguments, 3), source: argument(arguments, 4))
		case "cleanup":
			try cleanup(first)
		default:
			throw SimFailure(description: "unknown command \(command)")
		}
		return true
	}

	func capture(_ command: String, _ arguments: [String]) throws -> String {
		trimmed(try Shell.output(command, arguments))
	}

	func slug(_ value: String?, _ what: String) throws -> String {
		guard let value, value.wholeMatch(of: /[a-z0-9]+(?:-[a-z0-9]+)*/) != nil else {
			let shown = value.map { String(reflecting: $0) } ?? "nothing"
			throw SimFailure(description: "\(what) must be kebab-case, got \(shown)")
		}
		return value
	}

	func simName(_ id: String) -> String {
		"\(simPrefix)\(id)"
	}

	func devices() throws -> [Device] {
		let listing = try capture("xcrun", ["simctl", "list", "devices", "-j"])
		return try JSONDecoder().decode(DeviceList.self, from: Data(listing.utf8)).devices.values
			.flatMap { $0 }
	}

	func findSim(_ id: String) throws -> Device? {
		try devices().first { $0.name == simName(id) }
	}

	func iosRuntimes() throws -> [Runtime] {
		let listing = try capture("xcrun", ["simctl", "list", "runtimes", "-j"])
		return try JSONDecoder().decode(RuntimeList.self, from: Data(listing.utf8)).runtimes
			.filter { runtime in
				let major = runtime.version.split(separator: ".").first.flatMap { Int($0) } ?? 0
				return runtime.platform == "iOS" && runtime.isAvailable && major >= 26
			}
			.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
	}

	func nativeStates() throws -> [String] {
		var states: [String] = []
		for name in try contents(of: captures) where name.hasPrefix("native-") {
			var state = String(name.dropFirst("native-".count))
			for suffix in ["-light.png", "-dark.png"] where state.hasSuffix(suffix) {
				state = String(state.dropLast(suffix.count))
			}
			if !states.contains(state) {
				states.append(state)
			}
		}
		return states
	}

	func runDir(_ id: String?) throws -> URL {
		let dir = runsRoot.appendingPathComponent(try slug(id, "run id"))
		guard exists(dir.appendingPathComponent("run.json")) else {
			throw SimFailure(description: "unknown run \(id ?? ""); start one with: create <slug>")
		}
		return dir
	}

	func activeRun(_ id: String?) throws -> (dir: URL, udid: String) {
		let dir = try runDir(id)
		let name = try slug(id, "run id")
		guard let sim = try findSim(name) else {
			throw SimFailure(
				description: "simulator \(simName(name)) is gone; its evidence stays in \(dir.path)"
			)
		}
		return (dir, sim.udid)
	}

	func newestModification(_ urls: [URL]) throws -> TimeInterval {
		var newest: TimeInterval = 0
		for url in urls where exists(url) {
			let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
			if let date = attributes[.modificationDate] as? Date {
				newest = max(newest, date.timeIntervalSince1970)
			}
		}
		return newest
	}

	func exists(_ url: URL) -> Bool {
		FileManager.default.fileExists(atPath: url.path)
	}

	func contents(of url: URL) throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
	}

	func tail(_ log: URL) throws -> String {
		let lines = trimmed(try String(contentsOf: log, encoding: .utf8)).split(
			separator: "\n", omittingEmptySubsequences: false)
		return lines.suffix(25).joined(separator: "\n")
	}

	func stamp() -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd-HHmmss"
		return formatter.string(from: Date())
	}

	func write(_ record: RunRecord, to url: URL) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		var data = try encoder.encode(record)
		data.append(Data("\n".utf8))
		try data.write(to: url)
	}

	private func argument(_ arguments: [String], _ index: Int) -> String? {
		index < arguments.count ? arguments[index] : nil
	}
}

func trimmed(_ text: String) -> String {
	text.trimmingCharacters(in: .whitespacesAndNewlines)
}
