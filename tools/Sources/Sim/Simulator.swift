import CryptoKit
import Foundation
import ToolSupport

struct Device {
	let name: String
	let udid: String
	let state: String
}

struct Simulator {
	static let commands = [
		"doctor", "build", "create", "install", "launch", "shot", "test", "suite", "shard",
		"parity",
		"cleanup",
	]

	let repo: String
	let options: SimOptions
	let environment: [String: String]
	let executable: String
	let runsRoot: String
	let captures: String
	let deviceType: String
	let project: String
	let derivedData: String
	let products: String
	let appPath: String
	let sourceManifest: String
	let patterns = JavaScriptPatterns()
	let bundleID = "icu.enduragent.app"
	let simPrefix = "enduragent-verify-"
	let fixtureArguments = [
		"-EnduragentFixture", "first-week", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
	]
	let statusBar = [
		"--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
		"--cellularMode", "active", "--cellularBars", "4", "--batteryState", "charged",
		"--batteryLevel", "100",
	]

	init(repo: String, options: SimOptions, environment: [String: String], executable: String) {
		let home = environment["HOME"] ?? NSHomeDirectory()
		self.repo = repo
		self.options = options
		self.environment = environment
		self.executable = executable
		runsRoot =
			environment["ENDURAGENT_VERIFY_RUNS"]
			?? NodePath.join(home, "Library/Logs/enduragent-verify")
		captures =
			environment["ENDURAGENT_PROTOTYPE_CAPTURES"]
			?? NodePath.join(
				home, "projects/enduragent/desktop/docs/prototypes/ios/captures-2026-09-25")
		deviceType = environment["ENDURAGENT_SIM_DEVICE"] ?? "iPhone 17e"
		project = NodePath.join(repo, "apps/ios/Enduragent.xcodeproj")
		derivedData = options.buildFolder
		products = NodePath.join(derivedData, "Build/Products")
		appPath = NodePath.join(products, "Debug-iphonesimulator/Enduragent.app")
		sourceManifest = NodePath.join(derivedData, "verify-ios-sources.json")
	}

	func perform(_ command: String, _ arguments: [String]) throws -> Bool {
		func argument(_ index: Int) -> String? {
			index < arguments.count ? arguments[index] : nil
		}
		switch command {
		case "doctor":
			return try doctor(argument(0))
		case "build":
			try build()
		case "create":
			try create(argument(0))
		case "install":
			try install(argument(0))
		case "launch":
			try launch(argument(0), Array(arguments.dropFirst()))
		case "shot":
			try shot(argument(0), argument(1))
		case "test":
			let report = try test(argument(0), Array(arguments.dropFirst()))
			try report.throwFailures()
		case "suite":
			try suite(arguments)
		case "shard":
			try shard(argument(0), Array(arguments.dropFirst()))
		case "parity":
			try parity(
				argument(0), state: argument(1), theme: argument(2), flag: argument(3),
				source: argument(4))
		case "cleanup":
			try cleanup(argument(0))
		default:
			throw SimFailure(description: "unknown command \(command)")
		}
		return true
	}

	func capture(_ command: String, _ arguments: [String]) throws -> String {
		try Subprocess().capture(command, arguments)
	}

	func logged(_ log: String, _ command: String, _ arguments: [String]) throws -> SubprocessEnd {
		try Subprocess(directory: repo).logged(log, command, arguments)
	}

	func succeeds(_ command: String, _ arguments: [String]) throws -> Bool {
		try Subprocess().run(command, arguments, output: .discarded).succeeded
	}

	func exists(_ path: String) -> Bool {
		FileManager.default.fileExists(atPath: path)
	}

	func names(in folder: String) throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: folder).sorted {
			$0.utf8.lexicographicallyPrecedes($1.utf8)
		}
	}

	func makeFolder(_ path: String) throws {
		try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
	}

	func read(_ path: String) throws -> String {
		String(decoding: try FileSystem.read(path), as: UTF8.self)
	}

	func readJSON(_ path: String) throws -> JSONValue {
		try JSONValue.parse(try read(path))
	}

	func write(_ text: String, to path: String) throws {
		try Data(text.utf8).write(to: URL(fileURLWithPath: path))
	}

	func writeJSON(_ value: JSONValue, to path: String) throws {
		try write("\(value.indentedText)\n", to: path)
	}

	func tail(_ log: String) throws -> String {
		try read(log).trimmedEndAsJavaScript.split(
			separator: "\n", omittingEmptySubsequences: false
		)
		.suffix(25).joined(separator: "\n")
	}

	func stamp() -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd-HHmmss"
		return "\(formatter.string(from: Date()))-\(UUID().uuidString.lowercased().prefix(8))"
	}

	func slug(_ value: String?, _ what: String) throws -> String {
		guard let value, try patterns.test("^[a-z0-9]+(?:-[a-z0-9]+)*$", value) else {
			throw SimFailure(
				description: "\(what) must be kebab-case, got \(value?.quotedAsJSON ?? "undefined")"
			)
		}
		return value
	}

	func simName(_ id: String) -> String {
		"\(simPrefix)\(id)"
	}

	func devices() throws -> [Device] {
		let listed = try JSONValue.parse(capture("xcrun", ["simctl", "list", "devices", "-j"]))
		return try listed.member("devices").entries.flatMap { try $0.value.elements() }.map {
			device in
			Device(
				name: try device.member("name").interpolated,
				udid: try device.member("udid").interpolated,
				state: try device.member("state").interpolated)
		}
	}

	func findSim(_ id: String) throws -> Device? {
		try devices().first { $0.name.hasSameUnits(as: simName(id)) }
	}

	func iosRuntimes() throws -> [(name: String, identifier: String)] {
		let listed = try JSONValue.parse(capture("xcrun", ["simctl", "list", "runtimes", "-j"]))
		let available = try listed.member("runtimes").elements().compactMap {
			runtime -> (name: String, identifier: String, version: String)? in
			guard try runtime.member("platform").isString("iOS"),
				try runtime.member("isAvailable").isTruthy
			else { return nil }
			guard let version = try runtime.member("version").string else {
				throw SimFailure(description: "an available iOS runtime has no version")
			}
			let major = JavaScriptNumber.parse(
				String(version.split(separator: ".", omittingEmptySubsequences: false).first ?? ""))
			guard major >= 26 else { return nil }
			return (
				try runtime.member("name").interpolated,
				try runtime.member("identifier").interpolated,
				version
			)
		}
		return available.sorted {
			$0.version.compare(
				$1.version, options: .numeric, range: nil, locale: Locale(identifier: "en"))
				== .orderedDescending
		}.map { ($0.name, $0.identifier) }
	}

	func runDir(_ id: String?) throws -> String {
		let dir = NodePath.join(runsRoot, try slug(id, "run id"))
		guard exists(NodePath.join(dir, "run.json")) else {
			throw SimFailure(
				description: "unknown run \(id ?? "undefined"); start one with: create <slug>")
		}
		return dir
	}

	func activeRun(_ id: String?) throws -> (dir: String, udid: String) {
		let dir = try runDir(id)
		let name = try slug(id, "run id")
		guard let sim = try findSim(name) else {
			throw SimFailure(
				description: "simulator \(simName(name)) is gone; its evidence stays in \(dir)")
		}
		return (dir, sim.udid)
	}

	func sourceHashes() throws -> [JSONMember] {
		let ignored = [
			".build", ".swiftpm", "DerivedData", "build", "node_modules", "Enduragent.xcodeproj",
		]
		var hashes: [JSONMember] = []
		func walk(_ folder: String, _ relative: String) throws {
			let entries = try names(in: folder).sorted { $0.localeCompare($1) == .orderedAscending }
			for name in entries {
				let path = NodePath.join(folder, name)
				if ignored.contains(where: { $0.hasSameUnits(as: name) })
					|| path.hasSameUnits(as: derivedData)
				{
					continue
				}
				var status = stat()
				guard lstat(path, &status) == 0 else { throw FileFailure(code: errno, path: path) }
				switch status.st_mode & S_IFMT {
				case S_IFDIR:
					try walk(path, "\(relative)/\(name)")
				case S_IFREG:
					let digest = SHA256.hash(data: try FileSystem.read(path))
					hashes.append(
						JSONMember(
							key: "\(relative)/\(name)",
							value: .string(digest.map { String(format: "%02x", $0) }.joined())))
				default:
					throw SimFailure(
						description: "source must be a regular file or directory: \(path)")
				}
			}
		}
		try walk(NodePath.join(repo, "apps/ios"), "apps/ios")
		return hashes
	}

	func staleSource() throws -> String? {
		guard exists(sourceManifest) else { return "no source manifest from sim build" }
		let built = try readJSON(sourceManifest)
		let current = JSONValue.object(try sourceHashes())
		var files: [String] = []
		for member in built.entries + current.entries
		where !files.contains(where: { $0.hasSameUnits(as: member.key) }) {
			files.append(member.key)
		}
		let changed = try files.sorted { $0.isOrdered(before: $1) }.first { file in
			try !built.member(file).isSamePrimitive(as: current.member(file))
		}
		return changed.map { "\($0) differs from the last build" }
	}
}

struct ProofReport {
	var classes: [ClassResult]
	var failures: [String] = []

	func throwFailures() throws {
		if !failures.isEmpty { throw SimFailure(description: failures.joined(separator: "\n")) }
	}
}
