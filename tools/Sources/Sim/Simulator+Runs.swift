import CryptoKit
import Foundation
import ToolSupport

extension Simulator {
	func build() throws {
		_ = try capture(
			"xcodegen", ["generate", "--spec", NodePath.join(repo, "apps/ios/project.yml")])
		try makeFolder(derivedData)
		let log = NodePath.join(derivedData, "verify-ios-build.log")
		let hashes = try sourceHashes()
		let end = try logged(
			log, "xcodebuild",
			[
				"build-for-testing", "-project", project, "-scheme", "Enduragent", "-configuration",
				"Debug", "-sdk", "iphonesimulator", "-destination",
				"generic/platform=iOS Simulator",
				"-derivedDataPath", derivedData, "CODE_SIGNING_ALLOWED=NO",
			])
		guard end.succeeded else {
			throw SimFailure(
				description:
					"build-for-testing exited \(end.statusText); log \(log)\n\(try tail(log))")
		}
		try writeJSON(.object(hashes), to: sourceManifest)
		try Console.say("built \(appPath)\nlog \(log)")
	}

	func create(_ name: String?) throws {
		try createRun("\(stamp())-\(try slug(name, "run slug"))")
	}

	func createRun(_ id: String) throws {
		let dir = NodePath.join(runsRoot, id)
		if try exists(dir) || findSim(id) != nil {
			throw SimFailure(description: "run \(id) already exists")
		}
		guard let runtime = try iosRuntimes().first else {
			throw SimFailure(
				description:
					"no available iOS 26 simulator runtime; install one in Xcode > Settings > Components"
			)
		}
		try makeFolder(dir)
		let revision =
			try environment["ENDURAGENT_VERIFY_REVISION"]
			?? (exists(NodePath.join(repo, ".git"))
				? capture("git", ["-C", repo, "describe", "--always", "--dirty"]) : "exported-tree")
		let digest = SHA256.hash(data: Data(JSONValue.object(try sourceHashes()).compactText.utf8))
		let record: [JSONMember] = [
			JSONMember(key: "id", value: .string(id)),
			JSONMember(key: "simulator", value: .string(simName(id))),
			JSONMember(key: "deviceType", value: .string(deviceType)),
			JSONMember(key: "runtime", value: .string(runtime.name)),
			JSONMember(key: "checkout", value: .string(repo)),
			JSONMember(key: "revision", value: .string(revision)),
			JSONMember(key: "buildFolder", value: .string(derivedData)),
			JSONMember(
				key: "sourceDigest",
				value: .string(digest.map { String(format: "%02x", $0) }.joined())),
		]
		let recordFile = NodePath.join(dir, "run.json")
		try writeJSON(.object(record), to: recordFile)
		let udid = try capture(
			"xcrun", ["simctl", "create", simName(id), deviceType, runtime.identifier])
		try writeJSON(
			.object(record + [JSONMember(key: "udid", value: .string(udid))]), to: recordFile)
		do {
			_ = try capture("xcrun", ["simctl", "bootstatus", udid, "-b"])
			_ = try capture("xcrun", ["simctl", "status_bar", udid, "override"] + statusBar)
			_ = try capture("xcrun", ["simctl", "ui", udid, "appearance", "light"])
		} catch {
			try cleanup(id)
			throw error
		}
		try Console.say("run \(id)\nsimulator \(simName(id)) \(udid)\nevidence \(dir)")
	}

	func install(_ id: String?) throws {
		let run = try activeRun(id)
		guard exists(appPath) else {
			throw SimFailure(description: "no build at \(appPath); run build first")
		}
		_ = try capture("xcrun", ["simctl", "install", run.udid, appPath])
		try Console.say("installed \(bundleID) on \(run.udid)")
	}

	func launch(_ id: String?, _ extra: [String]) throws {
		let run = try activeRun(id)
		let keep = extra.contains { $0.hasSameUnits(as: "--keep") }
		let passthrough = extra.filter { !$0.hasSameUnits(as: "--keep") }
		try Console.say(
			try capture(
				"xcrun",
				["simctl", "launch", "--terminate-running-process", run.udid, bundleID]
					+ fixtureArguments + ["-EnduragentFixtureStore", keep ? "keep" : "fresh"]
					+ passthrough))
	}

	func shot(_ id: String?, _ label: String?) throws {
		let run = try activeRun(id)
		let path = NodePath.join(run.dir, "\(try slug(label, "label")).png")
		if exists(path) {
			throw SimFailure(description: "\(path) exists; evidence is never overwritten")
		}
		_ = try capture("xcrun", ["simctl", "io", run.udid, "screenshot", "--type=png", path])
		try Console.say(path)
	}

	func cleanup(_ id: String?) throws {
		let dir = try runDir(id)
		let name = try slug(id, "run id")
		if let sim = try findSim(name) {
			let shutdown = Result {
				if !sim.state.hasSameUnits(as: "Shutdown") {
					_ = try capture("xcrun", ["simctl", "shutdown", sim.udid])
				}
			}
			_ = try capture("xcrun", ["simctl", "delete", sim.udid])
			try shutdown.get()
			try Console.say("deleted \(simName(name)) \(sim.udid)")
		} else {
			try Console.say("no simulator \(simName(name)); nothing to delete")
		}
		if try findSim(name) != nil {
			throw SimFailure(description: "\(simName(name)) still exists after delete")
		}
		let kept = try names(in: dir).sorted { $0.isOrdered(before: $1) }
		try Console.say("evidence kept at \(dir)\n\(kept.joined(separator: "\n"))")
	}

	func parity(_ id: String?, state: String?, theme: String?, flag: String?, source: String?)
		throws
	{
		guard let theme, ["light", "dark"].contains(where: { $0.hasSameUnits(as: theme) }) else {
			throw SimFailure(description: "parity needs a theme: light or dark")
		}
		if let flag, !flag.hasSameUnits(as: "--from") || (source ?? "").isEmpty {
			throw SimFailure(description: "parity takes an optional --from <png>")
		}
		let name = try slug(state, "state")
		let prototype = NodePath.join(captures, "native-\(name)-\(theme).png")
		guard exists(prototype) else {
			var states: [String] = []
			for file in try names(in: captures) where file.hasUnitPrefix("native-") {
				let state = try patterns.replaceAll(
					#"^native-|-(?:light|dark)\.png$"#, file, with: "")
				if !states.contains(where: { $0.hasSameUnits(as: state) }) { states.append(state) }
			}
			throw SimFailure(
				description:
					"no prototype capture \(prototype)\nstates: \(states.joined(separator: " "))")
		}
		let run = try activeRun(id)
		let out = NodePath.join(run.dir, "parity", "\(name)-\(theme)")
		if exists(out) {
			throw SimFailure(description: "\(out) exists; evidence is never overwritten")
		}
		try makeFolder(out)
		let simulator = NodePath.join(out, "simulator.png")
		if let source {
			try FileManager.default.copyItem(atPath: source, toPath: simulator)
		} else {
			_ = try capture("xcrun", ["simctl", "ui", run.udid, "appearance", theme])
			Thread.sleep(forTimeInterval: 1.5)
			_ = try capture(
				"xcrun", ["simctl", "io", run.udid, "screenshot", "--type=png", simulator])
		}
		_ = try capture(
			"sips",
			["--resampleWidth", "390", simulator, "--out", NodePath.join(out, "simulator-390.png")])
		try FileManager.default.copyItem(
			atPath: prototype, toPath: NodePath.join(out, "prototype.png"))
		try Console.say(out)
	}
}
