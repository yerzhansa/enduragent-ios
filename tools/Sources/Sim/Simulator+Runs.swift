import Foundation
import ToolSupport

extension Simulator {
	func build() throws {
		_ = try capture(
			"xcodegen",
			["generate", "--spec", repo.appendingPathComponent("apps/ios/project.yml").path])
		try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
		let log = derivedData.appendingPathComponent("verify-ios-build.log")
		let status = try Shell.status(
			"xcodebuild",
			[
				"build-for-testing", "-project", project.path, "-scheme", "Enduragent",
				"-configuration", "Debug", "-sdk", "iphonesimulator", "-destination",
				"generic/platform=iOS Simulator", "-derivedDataPath", derivedData.path,
				"CODE_SIGNING_ALLOWED=NO",
			], log: log)
		guard status == 0 else {
			throw SimFailure(
				description: "build-for-testing exited \(status); log \(log.path)\n\(try tail(log))"
			)
		}
		try Console.say("built \(appPath.path)\nlog \(log.path)")
	}

	func create(_ name: String?) throws {
		let id = "\(stamp())-\(try slug(name, "run slug"))"
		let dir = runsRoot.appendingPathComponent(id)
		if try exists(dir) || findSim(id) != nil {
			throw SimFailure(description: "run \(id) already exists")
		}
		guard let runtime = try iosRuntimes().first else {
			throw SimFailure(
				description:
					"no available iOS 26 simulator runtime; install one in Xcode > Settings > Components"
			)
		}
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let recordURL = dir.appendingPathComponent("run.json")
		let revision = try capture("git", ["-C", repo.path, "describe", "--always", "--dirty"])
		func record(udid: String?) -> RunRecord {
			RunRecord(
				id: id, simulator: simName(id), deviceType: deviceType, runtime: runtime.name,
				checkout: repo.path, revision: revision, udid: udid)
		}
		try write(record(udid: nil), to: recordURL)
		let udid = try capture(
			"xcrun", ["simctl", "create", simName(id), deviceType, runtime.identifier])
		try write(record(udid: udid), to: recordURL)
		_ = try capture("xcrun", ["simctl", "bootstatus", udid, "-b"])
		_ = try capture("xcrun", ["simctl", "status_bar", udid, "override"] + statusBar)
		_ = try capture("xcrun", ["simctl", "ui", udid, "appearance", "light"])
		try Console.say("run \(id)\nsimulator \(simName(id)) \(udid)\nevidence \(dir.path)")
	}

	func install(_ id: String?) throws {
		let run = try activeRun(id)
		guard exists(appPath) else {
			throw SimFailure(description: "no build at \(appPath.path); run build first")
		}
		_ = try capture("xcrun", ["simctl", "install", run.udid, appPath.path])
		try Console.say("installed \(bundleId) on \(run.udid)")
	}

	func launch(_ id: String?, _ extra: [String]) throws {
		let run = try activeRun(id)
		try Console.say(
			try capture(
				"xcrun",
				["simctl", "launch", "--terminate-running-process", run.udid, bundleId]
					+ fixtureArguments + extra))
	}

	func shot(_ id: String?, _ label: String?) throws {
		let run = try activeRun(id)
		let path = run.dir.appendingPathComponent("\(try slug(label, "label")).png")
		if exists(path) {
			throw SimFailure(description: "\(path.path) exists; evidence is never overwritten")
		}
		_ = try capture("xcrun", ["simctl", "io", run.udid, "screenshot", "--type=png", path.path])
		try Console.say(path.path)
	}

	func cleanup(_ id: String?) throws {
		let dir = try runDir(id)
		let name = try slug(id, "run id")
		if let sim = try findSim(name) {
			if sim.state != "Shutdown" {
				_ = try capture("xcrun", ["simctl", "shutdown", sim.udid])
			}
			_ = try capture("xcrun", ["simctl", "delete", sim.udid])
			try Console.say("deleted \(simName(name)) \(sim.udid)")
		} else {
			try Console.say("no simulator \(simName(name)); nothing to delete")
		}
		if try findSim(name) != nil {
			throw SimFailure(description: "\(simName(name)) still exists after delete")
		}
		try Console.say(
			"evidence kept at \(dir.path)\n\(try contents(of: dir).joined(separator: "\n"))")
	}
}
