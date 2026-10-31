import Foundation
import Testing
import ToolSupport

extension SimCommandTests {
	@Test(
		"suite counts a class that fails beside others and passes alone as passed on rerun",
		.timeLimit(.minutes(2)))
	func suiteCountsAClassThatFailsBesideOthersAndPassesAlone() throws {
		try withTree { fixture in
			let result = try fixture.sim(
				["suite", "--shards", "1", "AlphaProof", "BravoProof"],
				environment: ["VERIFY_BUSY_CLASS": "AlphaProof"])
			#expect(result.status == 0, "\(result.output)\(result.errors)")
			#expect(result.output.contains("Passed\nPassed on rerun: AlphaProof\n"))
			#expect(try fixture.names(in: fixture.devices).isEmpty)
			let suite = try #require(
				try fixture.names(in: fixture.runs).first { !$0.contains("shard") })
			let summary = try JSONValue.parse(fixture.read("\(fixture.runs)/\(suite)/summary.json"))
			#expect(try summary.member("result").isString("Passed"))
			#expect(try summary.member("rerun").elements().map(\.interpolated) == ["AlphaProof"])
			let classes = try summary.member("classes").elements()
			func row(_ name: String) throws -> JSONValue {
				try #require(try classes.first { try $0.member("name").isString(name) })
			}
			#expect(try row("AlphaProof").member("passed").number == 1)
			#expect(try row("AlphaProof").member("failed").number == 0)
			#expect(try row("AlphaProof").member("firstRunFailed").number == 1)
			let bravoKeys = try row("BravoProof").entries.map(\.key)
			#expect(!bravoKeys.contains("firstRunFailed"))
			let markdown = try fixture.read("\(fixture.runs)/\(suite)/summary.md")
			let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(
				String.init)
			#expect(lines.first == "Passed")
			#expect(lines.dropFirst().first == "Passed on rerun: AlphaProof")
			let evidence = try summary.member("shards").member("0").member("directory").interpolated
			let kept = try fixture.names(in: evidence)
			#expect(kept.filter { $0.hasSuffix("-classes.json") }.count == 2)
			#expect(kept.filter { $0.hasSuffix("-attachments") }.count == 2)
			let calls = try fixture.calls()
			let runs = calls.enumerated().filter {
				$0.element.command == "xcodebuild"
					&& $0.element.arguments.contains("test-without-building")
			}
			let paired = try #require(
				runs.first { entry in
					entry.element.arguments.filter { $0.hasPrefix("-only-testing:") }.count > 1
				})
			let rerun = try #require(
				runs.first { entry in
					entry.element.arguments.filter { $0.hasPrefix("-only-testing:") }
						== ["-only-testing:EnduragentUITests/AlphaProof"]
				})
			let udid = String(
				try value(after: "-destination", in: rerun.element.arguments).dropFirst("id=".count)
			)
			let deleted = try #require(
				calls.enumerated().first { $0.element.arguments == ["simctl", "delete", udid] })
			#expect(paired.offset < rerun.offset)
			#expect(rerun.offset < deleted.offset)
		}
	}

	@Test("suite keeps a class that fails again on rerun as failed", .timeLimit(.minutes(2)))
	func suiteKeepsAClassThatFailsAgainOnRerun() throws {
		try withTree { fixture in
			let result = try fixture.sim(
				["suite", "--shards", "1", "AlphaProof", "BravoProof"],
				environment: ["VERIFY_FAIL_CLASS": "AlphaProof"])
			#expect(result.status == 1, "\(result.output)\(result.errors)")
			let suite = try #require(
				try fixture.names(in: fixture.runs).first { !$0.contains("shard") })
			let summary = try JSONValue.parse(fixture.read("\(fixture.runs)/\(suite)/summary.json"))
			#expect(try summary.member("result").isString("Failed"))
			#expect(try summary.member("rerun").elements().isEmpty)
			let classes = try summary.member("classes").elements()
			let alpha = try #require(
				try classes.first { try $0.member("name").isString("AlphaProof") })
			#expect(try alpha.member("passed").number == 0)
			#expect(try alpha.member("failed").number == 1)
			#expect(try alpha.member("firstRunFailed").number == 1)
		}
	}

	@Test("suite does not rerun when more than three classes fail", .timeLimit(.minutes(2)))
	func suiteDoesNotRerunWhenMoreThanThreeClassesFail() throws {
		try withTree { fixture in
			try fixture.write(
				"final class DeltaProof: XCTestCase {}\n",
				to: "\(fixture.tree)/apps/ios/EnduragentUITests/Delta.swift")
			let result = try fixture.sim(
				["suite", "--shards", "1"],
				environment: [
					"VERIFY_FAIL_CLASS": "AlphaProof,BravoProof,CharlieProof,DeltaProof"
				])
			#expect(result.status == 1, "\(result.output)\(result.errors)")
			let suite = try #require(
				try fixture.names(in: fixture.runs).first { !$0.contains("shard") })
			let summary = try JSONValue.parse(fixture.read("\(fixture.runs)/\(suite)/summary.json"))
			#expect(try summary.member("result").isString("Failed"))
			#expect(try summary.member("rerun").elements().isEmpty)
			let classes = try summary.member("classes").elements()
			#expect(
				try classes.map { try $0.member("name").interpolated }.sorted()
					== ["AlphaProof", "BravoProof", "CharlieProof", "DeltaProof"])
			for row in classes {
				#expect(try row.member("failed").number == 1)
				let keys = row.entries.map(\.key)
				#expect(!keys.contains("firstRunFailed"))
			}
			let proofRuns = try fixture.calls().filter {
				$0.command == "xcodebuild" && $0.arguments.contains("test-without-building")
			}
			#expect(proofRuns.count == 1)
		}
	}
}
