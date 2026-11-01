import Foundation
import ToolSupport

struct FixtureFailure: DescribedFailure {
	let description: String
}

@main
struct SimFixtureTool {
	let root: String
	let command: String
	let arguments: [String]
	let environment: [String: String]

	var devices: String { NodePath.join(root, "devices") }
	var deviceRecords: String { NodePath.join(root, "device-records") }
	var appearance: String { NodePath.join(root, "appearance") }

	static func main() throws {
		let environment = ProcessInfo.processInfo.environment
		guard let root = environment["ENDURAGENT_VERIFY_FAKE_ROOT"] else {
			throw FixtureFailure(description: "fake tools require a test-owned root")
		}
		let tool = SimFixtureTool(
			root: root, command: NodePath.basename(CommandLine.arguments[0]),
			arguments: Array(CommandLine.arguments.dropFirst()), environment: environment)
		exit(try tool.run())
	}

	func run() throws -> Int32 {
		for folder in [devices, deviceRecords] {
			try FileManager.default.createDirectory(
				atPath: folder, withIntermediateDirectories: true)
		}
		let moment = String(DispatchTime.now().uptimeNanoseconds)
		let call =
			"call-\(String(repeating: "0", count: 20 - moment.count))\(moment)-\(getpid()).json"
		try write(
			JSONValue.keyed([
				"command": .string(command), "args": .array(arguments.map(JSONValue.string)),
			]).compactText, to: NodePath.join(root, call))
		switch command {
		case "git":
			try FileHandle.standardError.write(contentsOf: Data("not a git repository\n".utf8))
			return 128
		case "xcodebuild":
			return try xcodebuild()
		case "plutil":
			try say("icu.enduragent.app\n")
		case "xcrun" where arguments.first == "xcresulttool":
			try resultTool()
		case "xcrun" where arguments.first == "simctl":
			return try simulatorControl()
		default:
			break
		}
		return 0
	}

	private func value(_ flag: String) throws -> String {
		guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
			throw FixtureFailure(description: "\(command) needs \(flag)")
		}
		return arguments[index + 1]
	}

	private func say(_ text: String) throws {
		try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
	}

	private func write(_ text: String, to path: String) throws {
		try Data(text.utf8).write(to: URL(fileURLWithPath: path))
	}

	private func read(_ path: String) throws -> String {
		String(decoding: try FileSystem.read(path), as: UTF8.self)
	}

	private func xcodebuild() throws -> Int32 {
		if arguments.contains("-version") {
			try say("Xcode 26.6\n")
			return 0
		}
		if arguments.contains("build-for-testing") {
			let products = NodePath.join(try value("-derivedDataPath"), "Build/Products")
			let app = NodePath.join(products, "Debug-iphonesimulator/Enduragent.app")
			try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
			try write("fixture", to: NodePath.join(app, "Info.plist"))
			try write("fixture", to: NodePath.join(products, "Enduragent.xctestrun"))
			return 0
		}
		let bundle = try value("-resultBundlePath")
		try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
		let selected = arguments.filter { $0.hasPrefix("-only-testing:") }
		let classes = selected.map { NodePath.segments($0).dropFirst().first ?? "" }
		var distinct: [String] = []
		for name in classes where !distinct.contains(name) { distinct.append(name) }
		let nodes = classes.filter { $0 != environment["VERIFY_MISSING_CLASS"] }.map { name in
			let result = classResult(name, among: distinct)
			return JSONValue.keyed([
				"name": .string(name), "nodeType": .string("Test Suite"),
				"children": .array([
					.keyed([
						"nodeType": .string("Test Case"),
						"nodeIdentifier": .string("\(name)/testVisibleResult()"),
						"result": .string(result), "durationInSeconds": .number(7),
					])
				]),
			])
		}
		try write(
			JSONValue.keyed(["testNodes": .array(nodes)]).compactText,
			to: NodePath.join(bundle, "tests.json"))
		let shown =
			FileManager.default.fileExists(atPath: appearance) ? try read(appearance) : "unset"
		let runs = NodePath.join(root, "proof-runs")
		let earlier = FileManager.default.fileExists(atPath: runs) ? try read(runs) : ""
		try write("\(earlier)\(shown) \(selected.joined(separator: " "))\n", to: runs)
		return classes.contains(where: { classResult($0, among: distinct) == "Failed" }) ? 65 : 0
	}

	private func classResult(_ name: String, among classes: [String]) -> String {
		if named("VERIFY_FAIL_CLASS").contains(name) { return "Failed" }
		if classes.count > 1, environment["VERIFY_BUSY_CLASS"] == name { return "Failed" }
		if environment["VERIFY_SKIP_CLASS"] == name { return "Skipped" }
		return "Passed"
	}

	private func named(_ variable: String) -> [String] {
		environment[variable]?.split(separator: ",").map(String.init) ?? []
	}

	private func resultTool() throws {
		if arguments.dropFirst().first == "export" {
			let tests = try JSONValue.parse(read(NodePath.join(try value("--path"), "tests.json")))
			let exported = try tests.member("testNodes").elements().map { node in
				JSONValue.keyed([
					"testIdentifier": try node.member("children").member("0").member(
						"nodeIdentifier"),
					"attachments": .array([
						.keyed([
							"exportedFileName": .string(
								"\(try node.member("name").interpolated).png"),
							"suggestedHumanReadableName": .string(
								"final screen_0_0F0E0D0C-1111-2222-3333-444455556666.png"),
						])
					]),
				])
			}
			try write(
				JSONValue.array(exported).compactText,
				to: NodePath.join(try value("--output-path"), "manifest.json"))
			return
		}
		let text = try read(NodePath.join(try value("--path"), "tests.json"))
		if arguments.count > 3, arguments[3] == "tests" {
			try say(text)
			return
		}
		let results = try JSONValue.parse(text).member("testNodes").elements().flatMap {
			try $0.member("children").elements().map { try $0.member("result").interpolated }
		}
		func count(_ result: String) -> JSONValue {
			.number(Double(results.filter { $0 == result }.count))
		}
		try say(
			JSONValue.keyed([
				"result": .string(results.contains("Failed") ? "Failed" : "Passed"),
				"passedTests": count("Passed"), "failedTests": count("Failed"),
				"skippedTests": count("Skipped"),
			]).compactText)
	}

	private func simulatorControl() throws -> Int32 {
		let action = arguments.count > 1 ? arguments[1] : ""
		switch action {
		case "list":
			try say(try listing(arguments.count > 2 ? arguments[2] : "").compactText)
		case "create":
			let udid = "fixture-\(getpid())"
			try write(
				JSONValue.keyed([
					"name": .string(try argument(2)), "udid": .string(udid),
					"state": .string("Booted"),
				]).compactText, to: NodePath.join(deviceRecords, udid))
			try write("", to: NodePath.join(devices, udid))
			try say(udid)
		case "delete":
			try FileManager.default.removeItem(atPath: NodePath.join(devices, try argument(2)))
		case "bootstatus" where environment["VERIFY_FAIL_BOOT"] != nil:
			let device = try JSONValue.parse(read(NodePath.join(deviceRecords, try argument(2))))
			if try device.member("name").interpolated.hasSuffix("shard-2") { return 1 }
		case "ui" where arguments.count > 4 && arguments[3] == "appearance":
			try write(arguments[4], to: appearance)
		default:
			break
		}
		return 0
	}

	private func argument(_ index: Int) throws -> String {
		guard index < arguments.count else {
			throw FixtureFailure(description: "\(command) needs more arguments")
		}
		return arguments[index]
	}

	private func listing(_ kind: String) throws -> JSONValue {
		switch kind {
		case "devices":
			let listed = try FileManager.default.contentsOfDirectory(atPath: devices).sorted()
			if environment["VERIFY_DELETE_DURING_LIST"] != nil {
				for device in listed {
					try FileManager.default.removeItem(atPath: NodePath.join(devices, device))
				}
			}
			let records = try listed.map {
				try JSONValue.parse(read(NodePath.join(deviceRecords, $0)))
			}
			return .keyed(["devices": .keyed(["fixture": .array(records)])])
		case "runtimes":
			return .keyed([
				"runtimes": .array([
					.keyed([
						"platform": .string("iOS"), "isAvailable": .bool(true),
						"version": .string("26.5"),
						"name": .string("iOS 26.5"), "identifier": .string("fixture-runtime"),
					])
				])
			])
		case "devicetypes":
			return .keyed(["devicetypes": .array([.keyed(["name": .string("iPhone 17e")])])])
		default:
			throw FixtureFailure(description: "no fake listing for \(kind)")
		}
	}
}
