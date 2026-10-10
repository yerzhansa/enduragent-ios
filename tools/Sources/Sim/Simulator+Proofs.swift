import Foundation
import ToolSupport

extension Simulator {
	func test(_ id: String?, _ proofs: [String]) throws -> ProofReport {
		guard !proofs.isEmpty else {
			throw SimFailure(
				description:
					"test needs at least one proof, for example: test <run> FirstConversationProof")
		}
		let run = try activeRun(id)
		_ = try capture("xcrun", ["simctl", "ui", run.udid, "appearance", "light"])
		return try runProofs(dir: run.dir, udid: run.udid, proofs: proofs)
	}

	private func runProofs(dir: String, udid: String, proofs: [String]) throws -> ProofReport {
		_ = try Subprocess().run(
			"xcrun", ["simctl", "terminate", udid, bundleID], output: .discarded)
		let name = "uitest-\(stamp())"
		let recordings = NodePath.join(recordingsRoot, NodePath.basename(dir))
		try makeFolder(recordings)
		let bundle = NodePath.join(recordings, "\(name).xcresult")
		let log = NodePath.join(dir, "\(name).log")
		let end = try logged(
			log, "xcodebuild",
			[
				"test-without-building", "-project", project, "-scheme", "Enduragent",
				"-destination",
				"id=\(udid)", "-derivedDataPath", derivedData, "-parallel-testing-enabled", "NO",
				"-resultBundlePath", bundle,
			] + proofs.map { "-only-testing:EnduragentUITests/\($0)" })
		var names: [String] = []
		for proof in proofs.map({ NodePath.segments($0)[0] })
		where !names.contains(where: { $0.hasSameUnits(as: proof) }) {
			names.append(proof)
		}
		var report = ProofReport(
			classes: try ShardPlan.summarize(.keyed(["testNodes": .array([])]), proofs: names))
		if !end.succeeded {
			report.failures.append(
				"test-without-building exited \(end.statusText)\n\(try tail(log))")
		}
		if exists(bundle) {
			let tests = try capture(
				"xcrun", ["xcresulttool", "get", "test-results", "tests", "--path", bundle])
			try write("\(tests)\n", to: NodePath.join(dir, "\(name)-tests.json"))
			report.classes = try ShardPlan.summarize(JSONValue.parse(tests), proofs: names)
			try writeJSON(
				.array(report.classes.map(\.json)), to: NodePath.join(dir, "\(name)-classes.json"))
			let attachments = NodePath.join(dir, "\(name)-attachments")
			try makeFolder(attachments)
			_ = try capture(
				"xcrun",
				[
					"xcresulttool", "export", "attachments", "--path", bundle, "--output-path",
					attachments,
				])
			let summary = try capture(
				"xcrun", ["xcresulttool", "get", "test-results", "summary", "--path", bundle])
			try write("\(summary)\n", to: NodePath.join(dir, "\(name)-summary.json"))
			let counts = try JSONValue.parse(summary)
			func count(_ key: String) throws -> String { try counts.member(key).interpolated }
			try Console.say(
				"\(try count("result")): \(try count("passedTests")) passed, \(try count("failedTests")) failed, \(try count("skippedTests")) skipped"
			)
			for entry in try readJSON(NodePath.join(attachments, "manifest.json")).elements() {
				let identifier = try entry.member("testIdentifier").interpolated
				for item in try entry.member("attachments").elements() {
					guard let suggested = try item.member("suggestedHumanReadableName").string
					else {
						throw SimFailure(description: "an attachment of \(identifier) has no name")
					}
					let stamped = try patterns.exec(#"_\d+_[0-9A-F\-]{36}(\.\w+)$"#, suggested)
					let label =
						stamped.map { suggested.slice(0, $0.index) + $0.groups[1] } ?? suggested
					let file = NodePath.join(
						attachments, try item.member("exportedFileName").interpolated)
					try Console.say("attachment \(identifier) \(label) \(file)")
				}
			}
		}
		for row in report.classes where row.isUnverified {
			report.failures.append(
				"\(row.name): \(row.failed) failed, \(row.skipped) skipped, \(row.missing) missing")
		}
		try Console.say("result bundle \(bundle)\nlog \(log)")
		return report
	}
}
