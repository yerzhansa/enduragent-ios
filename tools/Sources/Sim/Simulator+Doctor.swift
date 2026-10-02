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
		let xcode =
			try capture("xcodebuild", ["-version"]).split(separator: "\n").first.map(String.init)
			?? ""
		let xcodeMajor =
			xcode.replacingOccurrences(of: "Xcode ", with: "").split(separator: ".").first
			.flatMap { Int($0) } ?? 0
		check(xcodeMajor >= 26, xcode)
		let runtime = try iosRuntimes().first
		check(
			runtime != nil,
			runtime.map { "runtime \($0.name)" } ?? "no available iOS 26 simulator runtime")
		let typeListing = try capture("xcrun", ["simctl", "list", "devicetypes", "-j"])
		let types = try JSONDecoder().decode(DeviceTypeList.self, from: Data(typeListing.utf8))
			.devicetypes.map(\.name)
		check(types.contains(deviceType), "device type \(deviceType)")
		check(try Shell.status("xcodegen", ["--version"]) == 0, "xcodegen on PATH")
		let infoPlist = appPath.appendingPathComponent("Info.plist")
		let built = exists(infoPlist)
		check(built, "app build at \(appPath.path)")
		if built {
			let identifier = try capture(
				"plutil", ["-extract", "CFBundleIdentifier", "raw", infoPlist.path])
			check(identifier == bundleId, "bundle id \(identifier)")
			let freshness = try buildFreshness()
			check(freshness.fresh, freshness.text)
		}
		let runner =
			try exists(products) && contents(of: products).contains { $0.hasSuffix(".xctestrun") }
		check(runner, "UI test runner built (.xctestrun)")
		lines.append("\(exists(captures) ? "ok  " : "note") prototype captures at \(captures.path)")
		for device in try devices() where device.name.hasPrefix(simPrefix) {
			lines.append("note verify simulator \(device.name) \(device.udid) \(device.state)")
		}
		if let id {
			let evidence = runsRoot.appendingPathComponent(try slug(id, "run id"))
			check(
				exists(evidence.appendingPathComponent("run.json")),
				"run \(id) evidence at \(evidence.path)")
			let sim = try findSim(id)
			check(
				sim?.state == "Booted",
				"simulator \(simName(id)) \(sim.map { "\($0.udid) \($0.state)" } ?? "missing")")
			if let sim, sim.state == "Booted" {
				let installed = try Shell.status(
					"xcrun", ["simctl", "get_app_container", sim.udid, bundleId])
				check(installed == 0, "\(bundleId) installed")
				let running = try capture(
					"xcrun", ["simctl", "spawn", sim.udid, "launchctl", "list"]
				)
				.contains("UIKitApplication:\(bundleId)")
				lines.append("note \(bundleId) \(running ? "running" : "not running")")
			}
		}
		try Console.say(lines.joined(separator: "\n"))
		return !failed
	}

	private func buildFreshness() throws -> (fresh: Bool, text: String) {
		let sources = try capture(
			"git",
			[
				"-C", repo.path, "ls-files", "--cached", "--others", "--exclude-standard", "--",
				"apps/ios", ":!apps/ios/Enduragent.xcodeproj",
			]
		).split(separator: "\n").map(String.init)
		var newestFile = ""
		var newestTime: TimeInterval = 0
		for file in sources {
			let time = try newestModification([repo.appendingPathComponent(file)])
			if time > newestTime {
				newestFile = file
				newestTime = time
			}
		}
		let bundled = try contents(of: appPath).map { appPath.appendingPathComponent($0) }
		let builtAt = try newestModification([appPath] + bundled)
		guard builtAt >= newestTime else {
			return (false, "stale build: \(newestFile) changed after the last build; run build")
		}
		return (true, "build is newer than every source under apps/ios")
	}
}
