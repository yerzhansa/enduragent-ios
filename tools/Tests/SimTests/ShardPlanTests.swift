import Foundation
import Testing
import ToolSupport

@testable import Sim

struct ShardPlanTests {
	@Test("build folder parsing preserves the default and lets the flag override the environment")
	func parsesTheBuildFolder() throws {
		func parse(_ arguments: [String], _ environment: [String: String] = [:]) throws
			-> SimOptions
		{
			try SimOptions.parse(
				arguments, environment: environment, repo: "/tree", directory: "/work")
		}
		#expect(try parse(["build"]).buildFolder == "/tree/DerivedData")
		#expect(
			try parse(["build"], ["ENDURAGENT_VERIFY_BUILD": "/tmp/env-build"]).buildFolder
				== "/tmp/env-build")
		let parsed = try parse(
			[
				"suite", "AlphaProof", "--build-folder", "/tmp/flag-build", "--shards", "2",
				"--timings",
				"/tmp/times.json",
			], ["ENDURAGENT_VERIFY_BUILD": "/tmp/env-build"])
		#expect(
			parsed
				== SimOptions(
					command: "suite", arguments: ["AlphaProof"], buildFolder: "/tmp/flag-build",
					shards: 2,
					timings: "/tmp/times.json"))
		for arguments in [
			["suite", "--shards", "0"], ["suite", "--shards", "1.5"], ["build", "--build-folder"],
			["suite", "--timings"],
		] {
			#expect(throws: SimFailure.self) { try parse(arguments) }
		}
	}

	@Test("shard planner covers each class once and balances class counts without timings")
	func balancesClassCounts() throws {
		let proofs = ["AlphaProof", "BravoProof", "CharlieProof", "DeltaProof", "EchoProof"]
		let shards = try ShardPlan.plan(proofs, shards: 2)
		#expect(
			shards.map(\.proofs) == [
				["AlphaProof", "CharlieProof", "EchoProof"], ["BravoProof", "DeltaProof"],
			])
		#expect(shards.flatMap(\.proofs).sorted() == proofs)
		#expect(try ShardPlan.plan(proofs, shards: 3).map(\.proofs.count) == [2, 2, 1])
		#expect(
			failure { try ShardPlan.plan(["AlphaProof", "AlphaProof"], shards: 2) }.contains(
				"duplicate"))
		#expect(failure { try ShardPlan.plan(proofs, shards: 0) }.contains("shards"))
		#expect(failure { try ShardPlan.plan(["AlphaProof"], shards: 2) }.contains("classes"))
	}

	@Test("shard planner uses measured durations and a measured fallback for new classes")
	func usesMeasuredDurations() throws {
		let timings = JSONValue.keyed([
			"AlphaProof": .number(100), "BravoProof": .number(80), "CharlieProof": .number(20),
			"DeltaProof": .number(10),
		])
		let shards = try ShardPlan.plan(timings.entries.map(\.key), shards: 2, timings: timings)
		#expect(shards.map(\.estimatedSeconds) == [110, 100])
		let partial = try ShardPlan.plan(
			["AlphaProof", "NewProof"], shards: 2, timings: .keyed(["AlphaProof": .number(100)]))
		#expect(partial.map(\.estimatedSeconds) == [100, 100])
		#expect(
			failure {
				try ShardPlan.plan(
					["AlphaProof"], shards: 1, timings: .keyed(["AlphaProof": .number(-1)]))
			}.contains("duration"))
	}

	@Test("test result summary counts skipped tests and missing classes as unverified")
	func countsSkippedAndMissingAsUnverified() throws {
		let tree = try JSONValue.parse(
			"""
			{"testNodes": [{"children": [
				{"nodeType": "Test Case", "nodeIdentifier": "AlphaProof/testOne()", "result": "Passed", "durationInSeconds": 3},
				{"nodeType": "Test Case", "nodeIdentifier": "AlphaProof/testTwo()", "result": "Skipped", "durationInSeconds": 1},
				{"nodeType": "Test Case", "nodeIdentifier": "BravoProof/testOne()", "result": "Failed", "durationInSeconds": 2}
			]}]}
			""")
		let summary = try ShardPlan.summarize(
			tree, proofs: ["AlphaProof", "BravoProof", "MissingProof"])
		#expect(
			JSONValue.array(summary.map(\.json)).compactText
				== #"[{"name":"AlphaProof","passed":1,"failed":0,"skipped":1,"missing":0,"seconds":4},"#
				+ #"{"name":"BravoProof","passed":0,"failed":1,"skipped":0,"missing":0,"seconds":2},"#
				+ #"{"name":"MissingProof","passed":0,"failed":0,"skipped":0,"missing":1,"seconds":0}]"#
		)
	}

	@Test func plansEveryRecordedCaseAsTheNodePlannerDid() throws {
		let recorded = try #require(
			Bundle.module.url(forResource: "plans", withExtension: "json", subdirectory: "Fixtures")
		)
		let cases = try JSONValue.parse(String(decoding: Data(contentsOf: recorded), as: UTF8.self))
			.elements()
		#expect(cases.count > 200)
		for (index, planned) in cases.enumerated() {
			let proofs = try planned.member("proofs").elements().map(\.interpolated)
			let count = Int(try #require(try planned.member("shards").number))
			let timings = try planned.member("timings")
			let printed = Result { try ShardPlan.plan(proofs, shards: count, timings: timings) }.map
			{ plan in
				JSONValue.array(
					plan.map {
						.keyed([
							"proofs": .array($0.proofs.map(JSONValue.string)),
							"estimatedSeconds": .number($0.estimatedSeconds),
						])
					}
				).compactText
			}
			switch printed {
			case .success(let plan):
				#expect(plan == (try planned.member("plan").compactText), "case \(index)")
			case .failure(let error):
				#expect(
					error.localizedDescription == (try planned.member("error").string),
					"case \(index)")
			}
		}
	}

	@Test(arguments: [
		(0.25, "0.25", "0.3"), (0.75, "0.75", "0.8"), (1.25, "1.25", "1.3"), (2.5, "2.5", "2.5"),
		(0.05, "0.05", "0.1"), (1e21, "1e+21", "1e+21"), (1e-7, "1e-7", "0.0"),
		(0.000001, "0.000001", "0.0"),
		(1.2345678901234568e20, "123456789012345680000", "123456789012345683968.0"),
		(5e-324, "5e-324", "0.0"), (100, "100", "100.0"), (7.10, "7.1", "7.1"),
		(295.5580669641495, "295.5580669641495", "295.6"),
	])
	func writesSecondsAsNodeDoes(_ seconds: Double, _ text: String, _ rounded: String) {
		#expect(JavaScriptNumber.text(seconds) == text)
		#expect(JavaScriptNumber.fixedToOneDecimal(seconds) == rounded)
	}

	private func failure(_ body: () throws -> [Shard]) -> String {
		do {
			_ = try body()
			return ""
		} catch {
			return error.localizedDescription
		}
	}
}
