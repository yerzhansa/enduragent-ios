import Foundation
import ToolSupport

extension Simulator {
	func test(_ id: String?, _ proofs: [String]) throws {
		guard !proofs.isEmpty else {
			throw SimFailure(
				description:
					"test needs at least one proof, for example: test <run> FirstConversationProof")
		}
		let run = try activeRun(id)
		let name = "uitest-\(stamp())"
		let bundle = run.dir.appendingPathComponent("\(name).xcresult")
		let log = run.dir.appendingPathComponent("\(name).log")
		let status = try Shell.status(
			"xcodebuild",
			[
				"test-without-building", "-project", project.path, "-scheme", "Enduragent",
				"-destination", "id=\(run.udid)", "-derivedDataPath", derivedData.path,
				"-parallel-testing-enabled", "NO", "-resultBundlePath", bundle.path,
			] + proofs.map { "-only-testing:EnduragentUITests/\($0)" }, log: log)
		if exists(bundle) {
			try reportResults(bundle: bundle, dir: run.dir, name: name)
		}
		try Console.say("result bundle \(bundle.path)\nlog \(log.path)")
		guard status == 0 else {
			throw SimFailure(
				description: "test-without-building exited \(status)\n\(try tail(log))")
		}
	}

	func parity(
		_ id: String?, state: String?, theme: String?, flag: String?, source: String?
	) throws {
		guard let theme, ["light", "dark"].contains(theme) else {
			throw SimFailure(description: "parity needs a theme: light or dark")
		}
		if flag != nil && (flag != "--from" || (source ?? "").isEmpty) {
			throw SimFailure(description: "parity takes an optional --from <png>")
		}
		let prototype = captures.appendingPathComponent(
			"native-\(try slug(state, "state"))-\(theme).png")
		guard exists(prototype) else {
			throw SimFailure(
				description:
					"no prototype capture \(prototype.path)\nstates: \(try nativeStates().joined(separator: " "))"
			)
		}
		let run = try activeRun(id)
		let out = run.dir.appendingPathComponent("parity/\(try slug(state, "state"))-\(theme)")
		if exists(out) {
			throw SimFailure(description: "\(out.path) exists; evidence is never overwritten")
		}
		try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
		let simulator = out.appendingPathComponent("simulator.png")
		if let source {
			try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: simulator)
		} else {
			_ = try capture("xcrun", ["simctl", "ui", run.udid, "appearance", theme])
			Thread.sleep(forTimeInterval: 1.5)
			_ = try capture(
				"xcrun", ["simctl", "io", run.udid, "screenshot", "--type=png", simulator.path])
		}
		_ = try capture(
			"sips",
			[
				"--resampleWidth", "390", simulator.path, "--out",
				out.appendingPathComponent("simulator-390.png").path,
			])
		try FileManager.default.copyItem(
			at: prototype, to: out.appendingPathComponent("prototype.png"))
		try Console.say(out.path)
	}

	private func reportResults(bundle: URL, dir: URL, name: String) throws {
		let attachments = dir.appendingPathComponent("\(name)-attachments")
		try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
		_ = try capture(
			"xcrun",
			[
				"xcresulttool", "export", "attachments", "--path", bundle.path, "--output-path",
				attachments.path,
			])
		let summary = try capture(
			"xcrun", ["xcresulttool", "get", "test-results", "summary", "--path", bundle.path])
		try Data("\(summary)\n".utf8).write(to: dir.appendingPathComponent("\(name)-summary.json"))
		let result = try JSONDecoder().decode(TestSummary.self, from: Data(summary.utf8))
		try Console.say(
			"\(result.result): \(result.passedTests) passed, \(result.failedTests) failed, \(result.skippedTests) skipped"
		)
		let manifest = try JSONDecoder().decode(
			[AttachmentManifestEntry].self,
			from: Data(contentsOf: attachments.appendingPathComponent("manifest.json")))
		for entry in manifest {
			for item in entry.attachments {
				let label = item.suggestedHumanReadableName.replacing(
					/_\d+_[0-9A-F\-]{36}(?=\.\w+$)/, with: "")
				let path = attachments.appendingPathComponent(item.exportedFileName).path
				try Console.say("attachment \(entry.testIdentifier) \(label) \(path)")
			}
		}
	}
}
