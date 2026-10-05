import Foundation
import Testing
import ToolSupport

struct SuiteOutcome: Sendable, CustomTestStringConvertible {
	let label: String
	let environment: [String: String]
	let status: Int32

	var testDescription: String {
		"one suite command reports every class and deletes every owned simulator after \(label)"
	}

	static let all = [
		SuiteOutcome(label: "pass", environment: [:], status: 0),
		SuiteOutcome(label: "failure", environment: ["VERIFY_FAIL_CLASS": "AlphaProof"], status: 1),
		SuiteOutcome(
			label: "skip", environment: ["VERIFY_SKIP_CLASS": "BravoDarkProof"], status: 1),
		SuiteOutcome(
			label: "missing result", environment: ["VERIFY_MISSING_CLASS": "AlphaProof"], status: 1),
		SuiteOutcome(label: "boot failure", environment: ["VERIFY_FAIL_BOOT": "1"], status: 1),
	]
}

struct HelperFolder: Sendable, CustomTestStringConvertible {
	let path: String

	var testDescription: String {
		"the real build command through \(path) accepts a non-git export and an external build folder"
	}
}

struct SimCommandTests {
	private func withTree(_ body: (ExportedTree) throws -> Void) throws {
		let fixture = try ExportedTree()
		let outcome = Result { try body(fixture) }
		try fixture.remove()
		try outcome.get()
	}

	@Test(
		"fake device listings keep their snapshot when another shard deletes a listed device",
		.timeLimit(.minutes(1)))
	func fakeListingsKeepTheirSnapshot() throws {
		try withTree { fixture in
			let created = try fixture.fakeTool(
				"xcrun", ["simctl", "create", "snapshot-proof", "fixture-type", "fixture-runtime"])
			#expect(created.status == 0, "\(created.errors)")
			let udid = created.output.trimmedAsJavaScript
			let listed = try fixture.fakeTool(
				"xcrun", ["simctl", "list", "devices", "-j"],
				environment: ["VERIFY_DELETE_DURING_LIST": fixture.devices])
			#expect(listed.status == 0, "\(listed.errors)")
			#expect(
				listed.output
					== #"{"devices":{"fixture":[{"name":"snapshot-proof","udid":"\#(udid)","state":"Booted"}]}}"#
			)
			#expect(try fixture.names(in: fixture.devices).isEmpty)
		}
	}

	@Test(.timeLimit(.minutes(2)), arguments: ExportedTree.helperFolders.map(HelperFolder.init))
	func theRealBuildCommandAcceptsANonGitExportAndAnExternalBuildFolder(
		through folder: HelperFolder
	)
		throws
	{
		let helperFolder = folder.path
		try withTree { fixture in
			let result = try fixture.sim(
				["build", "--build-folder", fixture.build], through: helperFolder)
			#expect(result.status == 0, "\(result.errors)")
			#expect(fixture.exists("\(fixture.build)/verify-ios-sources.json"))
			#expect(!fixture.exists("\(fixture.tree)/DerivedData"))
			#expect(!fixture.exists("\(fixture.tree)/.git"))
			let ready = try fixture.sim(["doctor"], through: helperFolder)
			#expect(ready.status == 0, "\(ready.output)\(ready.errors)")
			try fixture.write(
				"final class NewProof: XCTestCase {}",
				to: "\(fixture.tree)/apps/ios/EnduragentUITests/New.swift")
			let stale = try fixture.sim(["doctor"], through: helperFolder)
			#expect(stale.status == 1, "\(stale.errors)")
			#expect(
				stale.output.split(separator: "\n").contains {
					$0.contains("stale build") && $0.contains("New.swift")
				})
		}
	}

	@Test(
		"suite command uses the caller timing file and the requested subset",
		.timeLimit(.minutes(2)))
	func suiteUsesTheCallerTimingFile() throws {
		try withTree { fixture in
			let timings = "\(fixture.root)/timings.json"
			try fixture.write(
				#"{"AlphaProof":10,"BravoDarkProof":100,"CharlieProof":90}"#, to: timings)
			let result = try fixture.sim(
				["suite", "--shards", "2", "--timings", timings, "AlphaProof", "BravoDarkProof"])
			#expect(result.status == 0, "\(result.errors)")
			let suite = try #require(
				try fixture.names(in: fixture.runs).first { !$0.contains("shard") })
			let plan = try JSONValue.parse(fixture.read("\(fixture.runs)/\(suite)/plan.json"))
			let shards = try plan.member("shards").elements()
			#expect(
				try shards.map { try $0.member("proofs").compactText } == [
					#"["BravoDarkProof"]"#, #"["AlphaProof"]"#,
				])
			#expect(try shards.map { try $0.member("estimatedSeconds").number } == [100, 10])
		}
	}

	@Test(
		"suite rejects a missing timing file before creating a simulator or building",
		.timeLimit(.minutes(1)))
	func suiteRejectsAMissingTimingFile() throws {
		try withTree { fixture in
			let result = try fixture.sim(
				["suite", "--shards", "2", "--timings", "\(fixture.root)/missing.json"])
			#expect(result.status == 1, "\(result.errors)")
			#expect(result.errors.contains("timing file missing"))
			#expect(!fixture.exists(fixture.devices))
		}
	}

	@Test(.timeLimit(.minutes(2)), arguments: SuiteOutcome.all)
	func oneSuiteCommandReportsEveryClassAndDeletesEveryOwnedSimulator(after outcome: SuiteOutcome)
		throws
	{
		try withTree { fixture in
			let result = try fixture.sim(
				["suite", "--shards", "2"], environment: outcome.environment)
			#expect(result.status == outcome.status, "\(result.errors)")
			#expect(try fixture.names(in: fixture.devices).isEmpty)
			let suite = try #require(
				try fixture.names(in: fixture.runs).first { !$0.contains("shard") })
			let summary = try JSONValue.parse(fixture.read("\(fixture.runs)/\(suite)/summary.json"))
			let classes = try summary.member("classes").elements()
			func row(_ name: String) throws -> JSONValue {
				try #require(try classes.first { try $0.member("name").isString(name) })
			}
			#expect(
				try classes.map { try $0.member("name").interpolated }.sorted()
					== ["AlphaProof", "BravoDarkProof", "CharlieProof"])
			let shards = try summary.member("shards").elements()
			#expect(shards.count == 2)
			for shard in shards {
				#expect(
					fixture.exists("\(try shard.member("directory").interpolated)/summary.json"))
			}
			if outcome.label == "skip" {
				#expect(try row("BravoDarkProof").member("skipped").number == 1)
			}
			if outcome.label == "missing result" {
				#expect(try row("AlphaProof").member("missing").number == 1)
			}
			let calls = try fixture.calls().map(\.arguments)
			#expect(calls.filter { $0.contains("build-for-testing") }.count == 1)
			for call in calls where call.contains("test-without-building") {
				#expect(try value(after: "-parallel-testing-enabled", in: call) == "NO")
				#expect(try value(after: "-derivedDataPath", in: call) == fixture.build)
			}
		}
	}

	@Test(
		"OpenRouter phone helper requires an operator terminal before approval or launch",
		.timeLimit(.minutes(1)))
	func openRouterHelperRequiresAnOperatorTerminal() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
			"enduragent-openrouter-guard-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
		let evidence = folder.appendingPathComponent("evidence").path
		let result = Result {
			try Subprocess().collect(
				"\(ExportedTree.products)/phone-check",
				["openrouter", "tool", "synthetic-device", evidence])
		}
		let exists = FileManager.default.fileExists(atPath: evidence)
		try FileManager.default.removeItem(at: folder)
		let finished = try result.get()
		#expect(finished.end.status != 0)
		#expect(
			String(decoding: finished.errors, as: UTF8.self).contains(
				"An operator terminal is required before approval, build, launch or Send"))
		#expect(!exists)
	}

	@Test(
		"proof commands select their appearance and restore light after a dark failure",
		.timeLimit(.minutes(2)))
	func proofCommandsSelectTheirAppearance() throws {
		try withTree { fixture in
			try FileManager.default.createDirectory(
				atPath: "\(fixture.runs)/fixture", withIntermediateDirectories: true)
			try fixture.write("{}", to: "\(fixture.runs)/fixture/run.json")
			let created = try fixture.fakeTool(
				"xcrun",
				[
					"simctl", "create", "enduragent-verify-fixture", "fixture-type",
					"fixture-runtime",
				])
			let udid = created.output.trimmedAsJavaScript
			let recorded = "\(fixture.root)/proof-runs"
			for (proofs, fails) in [
				(["ConfirmedPreviewProof"], false),
				(["ConfirmedPreviewProof", "ConfirmedPreviewDarkProof"], false),
				(["ConfirmedPreviewDarkProof"], true),
			] {
				_ = try fixture.fakeTool("xcrun", ["simctl", "ui", udid, "appearance", "dark"])
				if fixture.exists(recorded) { try FileManager.default.removeItem(atPath: recorded) }
				let result = try fixture.sim(
					["test", "fixture"] + proofs,
					environment: fails ? ["VERIFY_FAIL_CLASS": "ConfirmedPreviewDarkProof"] : [:])
				#expect(result.status == (fails ? 1 : 0), "\(result.errors)")
				#expect(try fixture.read("\(fixture.root)/appearance") == "light")
				#expect(
					try fixture.read(recorded).split(separator: "\n").map(String.init)
						== proofs.map {
							"\($0.hasSuffix("DarkProof") ? "dark" : "light") -only-testing:EnduragentUITests/\($0)"
						})
			}
		}
	}

	@Test(.timeLimit(.minutes(2)))
	func oneRunLeavesTheEvidenceLayoutSimulatorAgentsRead() throws {
		try withTree { fixture in
			#expect(try fixture.sim(["build"]).status == 0)
			let created = try fixture.sim(
				["create", "smoke-check"], environment: ["ENDURAGENT_VERIFY_REVISION": "abc1234"])
			#expect(created.status == 0, "\(created.errors)")
			let lines = created.output.split(separator: "\n").map(String.init)
			let run = String(try #require(lines.first).dropFirst("run ".count))
			let folder = "\(fixture.runs)/\(run)"
			let patterns = JavaScriptPatterns()
			#expect(try patterns.test(#"^\d{4}-\d{2}-\d{2}-\d{6}-[0-9a-f]{8}-smoke-check$"#, run))
			let record = try JSONValue.parse(fixture.read("\(folder)/run.json"))
			let udid = try record.member("udid").interpolated
			#expect(
				lines.dropFirst() == [
					"simulator enduragent-verify-\(run) \(udid)", "evidence \(folder)",
				])
			#expect(
				record.entries.map(\.key) == [
					"id", "simulator", "deviceType", "runtime", "checkout", "revision",
					"buildFolder",
					"sourceDigest", "udid",
				])
			#expect(try record.member("checkout").isString(fixture.tree))
			#expect(try record.member("revision").isString("abc1234"))
			#expect(try record.member("buildFolder").isString(fixture.build))
			#expect(
				try fixture.sim(["install", run]).output
					== "installed icu.enduragent.app on \(udid)\n")
			#expect(
				try fixture.sim(["launch", run, "--keep", "-EnduragentFixtureReply", "slow"]).status
					== 0)
			#expect(
				try fixture.sim(["shot", run, "first-screen"]).output
					== "\(folder)/first-screen.png\n")
			let tested = try fixture.sim([
				"test", run, "AlphaProof", "BravoDarkProof/testVisibleResult",
			])
			#expect(tested.status == 0, "\(tested.errors)")
			let stamps = try patterns.matchAll(
				#"(?:^|\n)log \S+/(uitest-[0-9a-f\-]+)\.log"#, tested.output
			).map { $0.groups[1] }
			#expect(stamps.count == 2)
			let light = try #require(stamps.first)
			#expect(
				tested.output.hasPrefix(
					"Passed: 1 passed, 0 failed, 0 skipped\n"
						+ "attachment AlphaProof/testVisibleResult() final screen.png \(folder)/\(light)-attachments/AlphaProof.png\n"
						+ "result bundle \(folder)/\(light).xcresult\nlog \(folder)/\(light).log\n")
			)
			#expect(
				try fixture.read("\(folder)/\(light)-classes.json")
					== "[\n  {\n    \"name\": \"AlphaProof\",\n    \"passed\": 1,\n    \"failed\": 0,\n    \"skipped\": 0,\n    \"missing\": 0,\n    \"seconds\": 7\n  }\n]\n"
			)
			let cleaned = try fixture.sim(["cleanup", run])
			#expect(cleaned.status == 0, "\(cleaned.errors)")
			let kept =
				["run.json"]
				+ stamps.sorted().flatMap { stamp in
					[
						"-attachments", "-classes.json", "-summary.json", "-tests.json", ".log",
						".xcresult",
					].map { "\(stamp)\($0)" }
				}
			#expect(try fixture.names(in: folder) == kept)
			#expect(
				cleaned.output
					== "deleted enduragent-verify-\(run) \(udid)\nevidence kept at \(folder)\n\(kept.joined(separator: "\n"))\n"
			)
			let launches = try fixture.calls().map(\.arguments).filter { $0.contains("launch") }
			#expect(
				launches == [
					[
						"simctl", "launch", "--terminate-running-process", udid,
						"icu.enduragent.app",
						"-EnduragentFixture", "first-week", "-AppleLanguages", "(en)",
						"-AppleLocale", "en_US",
						"-EnduragentFixtureStore", "keep", "-EnduragentFixtureReply", "slow",
					]
				])
		}
	}

	private func value(after flag: String, in call: [String]) throws -> String {
		let index = try #require(call.firstIndex(of: flag))
		return call[index + 1]
	}
}
