import Foundation
import ToolSupport

private struct PlannedShard {
	let shard: Shard
	let id: String
	let directory: String
	let log: String

	var members: [JSONMember] {
		[
			JSONMember(key: "proofs", value: .array(shard.proofs.map(JSONValue.string))),
			JSONMember(key: "estimatedSeconds", value: .number(shard.estimatedSeconds)),
			JSONMember(key: "id", value: .string(id)),
			JSONMember(key: "directory", value: .string(directory)),
			JSONMember(key: "log", value: .string(log)),
		]
	}
}

extension ProofReport {
	var json: JSONValue {
		.keyed([
			"classes": .array(classes.map(\.json)),
			"failures": .array(failures.map(JSONValue.string)),
		])
	}

	init(json: JSONValue) throws {
		classes = try json.member("classes").elements().map(ClassResult.init(json:))
		failures = try json.member("failures").elements().map(\.interpolated)
	}
}

extension Simulator {
	private static let failedClassRerunLimit = 3

	func shard(_ id: String?, _ proofs: [String]) throws {
		let name = try slug(id, "shard id")
		let dir = NodePath.join(runsRoot, name)
		var report = ProofReport(
			classes: try ShardPlan.summarize(.keyed(["testNodes": .array([])]), proofs: proofs))
		var returned = false
		do {
			try createRun(name)
			try install(name)
			report = try test(name, proofs)
			returned = true
		} catch {
			report.failures.append(Console.text(of: error))
		}
		if returned { rerunFailedClasses(name, report: &report) }
		if exists(NodePath.join(dir, "run.json")) {
			do {
				try cleanup(name)
			} catch {
				report.failures.append("cleanup: \(Console.text(of: error))")
			}
		}
		if !returned && exists(dir) {
			report.classes = try recoveredClasses(in: dir, fallback: report.classes)
		}
		try makeFolder(dir)
		try writeJSON(report.json, to: NodePath.join(dir, "summary.json"))
		try report.throwFailures()
	}

	func suite(_ requested: [String]) throws {
		let standing = try ShardPlan.proofClasses(repo: repo)
		let proofs = requested.isEmpty ? standing : requested
		let named = try standing + ShardPlan.proofClasses(repo: repo, ending: "Sweep")
		for proof in proofs where !named.contains(where: { $0.hasSameUnits(as: proof) }) {
			throw SimFailure(description: "unknown UI proof class \(proof)")
		}
		let timingFile = options.timings ?? NodePath.join(runsRoot, "timings.json")
		if options.timings != nil, !exists(timingFile) {
			throw SimFailure(description: "timing file missing: \(timingFile)")
		}
		let timings = exists(timingFile) ? try readJSON(timingFile) : .object([])
		let plan = try ShardPlan.plan(proofs, shards: options.shards, timings: timings)
		let id = "\(stamp())-suite"
		let dir = NodePath.join(runsRoot, id)
		try makeFolder(dir)
		let shards = plan.enumerated().map { index, shard in
			PlannedShard(
				shard: shard, id: "\(id)-shard-\(index + 1)",
				directory: NodePath.join(runsRoot, "\(id)-shard-\(index + 1)"),
				log: NodePath.join(dir, "shard-\(index + 1).log"))
		}
		try writeJSON(
			.keyed([
				"buildFolder": .string(derivedData), "timingFile": .string(timingFile),
				"shards": .array(shards.map { .object($0.members) }),
			]), to: NodePath.join(dir, "plan.json"))
		try build()
		let ends = try runShards(shards)
		var reports: [(shard: PlannedShard, report: ProofReport)] = []
		for (shard, end) in zip(shards, ends) {
			let file = NodePath.join(shard.directory, "summary.json")
			var report = ProofReport(
				classes: try ShardPlan.summarize(
					.keyed(["testNodes": .array([])]), proofs: shard.shard.proofs),
				failures: ["shard wrote no summary"])
			do {
				if try exists(NodePath.join(shard.directory, "run.json"))
					&& findSim(shard.id) != nil
				{
					try cleanup(shard.id)
				}
				if exists(file) { report = try ProofReport(json: readJSON(file)) }
			} catch {
				report.failures.append(Console.text(of: error))
			}
			switch end {
			case .failure(let error):
				report.failures.append(Console.text(of: error))
			case .success(let end) where !end.succeeded:
				report.failures.append("shard exited \(end.statusText), signal \(end.signalText)")
			case .success:
				break
			}
			try makeFolder(shard.directory)
			try writeJSON(report.json, to: file)
			reports.append((shard, report))
		}
		let classes = reports.flatMap(\.report.classes).sorted {
			$0.name.localeCompare($1.name) == .orderedAscending
		}
		let failed =
			reports.contains { !$0.report.failures.isEmpty }
			|| classes.contains(where: \.isUnverified)
		let result = failed ? "Failed" : "Passed"
		let rerun =
			classes.filter { $0.firstRunFailed != nil && !$0.isUnverified }.map(\.name).sorted {
				$0.localeCompare($1) == .orderedAscending
			}
		let rerunLine = rerun.isEmpty ? "" : "Passed on rerun: \(rerun.joined(separator: ", "))\n"
		try writeJSON(
			.keyed([
				"result": .string(result), "rerun": .array(rerun.map(JSONValue.string)),
				"classes": .array(classes.map(\.json)),
				"shards": .array(
					reports.map { .object($0.shard.members + $0.report.json.entries) }),
			]), to: NodePath.join(dir, "summary.json"))
		let rows = classes.map { row in
			"| \(row.name) | \(row.passed) | \(row.failed) | \(row.skipped) | \(row.missing) | \(JavaScriptNumber.fixedToOneDecimal(row.seconds)) |"
		}
		let table =
			[
				"| Class | Passed | Failed | Skipped | Missing | Seconds |",
				"| --- | --- | --- | --- | --- | --- |",
			]
			+ rows
		try write(
			"\(result)\n\(rerunLine)\n\(table.joined(separator: "\n"))\n",
			to: NodePath.join(dir, "summary.md"))
		var merged = timings.entries
		for row in classes where row.passed != 0 && !row.isUnverified && row.seconds > 0 {
			if let known = merged.firstIndex(where: { $0.key.hasSameUnits(as: row.name) }) {
				merged[known].value = .number(row.seconds)
			} else {
				merged.append(JSONMember(key: row.name, value: .number(row.seconds)))
			}
		}
		try writeJSON(.object(merged), to: NodePath.join(dir, "timings.json"))
		try Console.say(
			"\(result)\n\(rerunLine)combined summary \(NodePath.join(dir, "summary.md"))\ntimings \(NodePath.join(dir, "timings.json"))"
		)
		if failed {
			throw SimFailure(
				description: "proof suite failed; see \(NodePath.join(dir, "summary.json"))")
		}
	}

	private func rerunFailedClasses(_ name: String, report: inout ProofReport) {
		let failed = report.classes.filter { $0.failed != 0 }
		guard !failed.isEmpty, failed.count <= Self.failedClassRerunLimit,
			report.classes.allSatisfy({ $0.skipped == 0 && $0.missing == 0 })
		else { return }
		report.failures = []
		for original in failed {
			do {
				let attempt = try test(name, [original.name])
				report.failures += attempt.failures
				guard
					let measured = attempt.classes.first(where: {
						$0.name.hasSameUnits(as: original.name)
					}),
					let index = report.classes.firstIndex(where: {
						$0.name.hasSameUnits(as: original.name)
					})
				else { throw SimFailure(description: "rerun omitted \(original.name)") }
				report.classes[index] = measured
				report.classes[index].firstRunFailed = original.failed
			} catch {
				report.failures.append(Console.text(of: error))
			}
		}
	}

	private func recoveredClasses(in dir: String, fallback: [ClassResult]) throws -> [ClassResult] {
		let measured = try names(in: dir).filter { $0.hasUnitSuffix("-classes.json") }.flatMap {
			try readJSON(NodePath.join(dir, $0)).elements().map(ClassResult.init(json:))
		}
		return fallback.map { row in
			measured.first { $0.name.hasSameUnits(as: row.name) } ?? row
		}
	}

	private func runShards(_ shards: [PlannedShard]) throws -> [Result<SubprocessEnd, Error>] {
		var shardEnvironment = environment
		shardEnvironment["ENDURAGENT_VERIFY_BUILD"] = derivedData
		let runner = Subprocess(directory: repo, environment: shardEnvironment)
		let started = shards.map { shard in
			Result {
				let descriptor = open(shard.log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
				guard descriptor >= 0 else { throw FileFailure(code: errno, path: shard.log) }
				defer { close(descriptor) }
				return try runner.start(
					executable, ["shard", shard.id] + shard.shard.proofs,
					output: .file(FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)))
			}
		}
		return try started.enumerated().map { index, start in
			if case .failure(let error) = start {
				try Console.complain("shard \(shards[index].id): \(Console.text(of: error))")
			}
			return start.map { process in
				process.waitUntilExit()
				return Subprocess.end(of: process)
			}
		}
	}
}
