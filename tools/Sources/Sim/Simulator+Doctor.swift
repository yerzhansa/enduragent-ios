import Foundation
import ToolSupport

extension Simulator {
	func doctor(_ id: String?) throws -> Bool {
		var lines: [String] = []
		var failed = false
		func check(_ passed: Bool, _ text: String) {
			failed = failed || !passed
			lines.append("\(passed ? "ok  " : "FAIL") \(text)")
		}
		let xcode = String(
			try capture("xcodebuild", ["-version"]).split(
				separator: "\n", omittingEmptySubsequences: false
			)
			.first ?? "")
		var version = xcode
		if let name = version.range(of: "Xcode ", options: .literal) {
			version.removeSubrange(name)
		}
		let major = JavaScriptNumber.parse(
			String(version.split(separator: ".", omittingEmptySubsequences: false).first ?? ""))
		check(major >= 26, xcode)
		let runtime = try iosRuntimes().first
		check(
			runtime != nil,
			runtime.map { "runtime \($0.name)" } ?? "no available iOS 26 simulator runtime")
		let types = try JSONValue.parse(capture("xcrun", ["simctl", "list", "devicetypes", "-j"]))
			.member("devicetypes").elements()
		check(
			try types.contains { try $0.member("name").isString(deviceType) },
			"device type \(deviceType)")
		check(try succeeds("xcodegen", ["--version"]), "xcodegen on PATH")
		let information = NodePath.join(appPath, "Info.plist")
		let built = exists(information)
		check(built, "app build at \(appPath)")
		if built {
			let identifier = try capture(
				"plutil", ["-extract", "CFBundleIdentifier", "raw", information])
			check(identifier.hasSameUnits(as: bundleID), "bundle id \(identifier)")
			let stale = try staleSource()
			check(
				stale == nil,
				stale.map { "stale build: \($0); run build" }
					?? "build matches the content of every source under apps/ios")
		}
		check(
			try exists(products) && names(in: products).contains { $0.hasUnitSuffix(".xctestrun") },
			"UI test runner built (.xctestrun)")
		lines.append("\(exists(captures) ? "ok  " : "note") prototype captures at \(captures)")
		for device in try devices() where device.name.hasUnitPrefix(simPrefix) {
			lines.append("note verify simulator \(device.name) \(device.udid) \(device.state)")
		}
		if let id, !id.isEmpty {
			let evidence = NodePath.join(runsRoot, try slug(id, "run id"), "run.json")
			check(exists(evidence), "run \(id) evidence at \(NodePath.join(runsRoot, id))")
			let sim = try findSim(id)
			let booted = sim?.state.hasSameUnits(as: "Booted") ?? false
			check(
				booted,
				"simulator \(simName(id)) \(sim.map { "\($0.udid) \($0.state)" } ?? "missing")")
			if let sim, booted {
				check(
					try succeeds("xcrun", ["simctl", "get_app_container", sim.udid, bundleID]),
					"\(bundleID) installed")
				let running = try capture(
					"xcrun", ["simctl", "spawn", sim.udid, "launchctl", "list"]
				)
				.contains("UIKitApplication:\(bundleID)")
				lines.append("note \(bundleID) \(running ? "running" : "not running")")
			}
		}
		try Console.say(lines.joined(separator: "\n"))
		return !failed
	}
}
