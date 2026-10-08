import Foundation
import ToolSupport

struct Shard: Equatable {
	var proofs: [String] = []
	var estimatedSeconds = 0.0
}

struct ClassResult: Equatable {
	let name: String
	var passed = 0
	var failed = 0
	var skipped = 0
	var missing = 0
	var seconds = 0.0

	var isUnverified: Bool { failed != 0 || skipped != 0 || missing != 0 }

	var json: JSONValue {
		.keyed([
			"name": .string(name), "passed": .number(Double(passed)),
			"failed": .number(Double(failed)),
			"skipped": .number(Double(skipped)), "missing": .number(Double(missing)),
			"seconds": .number(seconds),
		])
	}

	init(name: String) {
		self.name = name
	}

	init(json: JSONValue) throws {
		func count(_ key: String) throws -> Int {
			guard let value = try json.member(key).number, let whole = Int(exactly: value) else {
				throw SimFailure(description: "class result has no \(key) count")
			}
			return whole
		}
		guard let name = try json.member("name").string,
			let seconds = try json.member("seconds").number
		else {
			throw SimFailure(description: "class result has no name or seconds")
		}
		self.name = name
		self.seconds = seconds
		passed = try count("passed")
		failed = try count("failed")
		skipped = try count("skipped")
		missing = try count("missing")
	}
}

enum ShardPlan {
	static func proofClasses(repo: String, ending suffix: String = "Proof") throws -> [String] {
		let folder = NodePath.join(repo, "apps/ios/EnduragentUITests")
		let patterns = JavaScriptPatterns()
		var classes: [String] = []
		let files = try FileManager.default.contentsOfDirectory(atPath: folder).sorted {
			$0.utf8.lexicographicallyPrecedes($1.utf8)
		}
		for file in files where file.hasUnitSuffix(".swift") {
			let text = String(
				decoding: try FileSystem.read(NodePath.join(folder, file)), as: UTF8.self)
			classes += try patterns.matchAll(
				#"\bfinal\s+class\s+(\w+"# + suffix + #")\s*:\s*XCTestCase\b"#, text
			).map { $0.groups[1] }
		}
		return classes.sorted { $0.isOrdered(before: $1) }
	}

	static func plan(_ proofs: [String], shards count: Int, timings: JSONValue = .object([])) throws
		-> [Shard]
	{
		guard count >= 1 else {
			throw SimFailure(description: "shards must be a positive whole number")
		}
		guard proofs.count >= count else {
			throw SimFailure(description: "need at least as many classes as shards")
		}
		var seen: [String] = []
		for proof in proofs {
			guard !seen.contains(where: { $0.hasSameUnits(as: proof) }) else {
				throw SimFailure(description: "duplicate proof class")
			}
			seen.append(proof)
		}
		let patterns = JavaScriptPatterns()
		guard try proofs.allSatisfy({ try patterns.test(#"^[A-Za-z_]\w*$"#, $0) }) else {
			throw SimFailure(description: "suite takes class names, not test methods")
		}
		guard case .object(let measured) = timings else {
			throw SimFailure(description: "timings must map class names to seconds")
		}
		let durations = measured.map { $0.value.number ?? .nan }
		guard durations.allSatisfy({ $0.isFinite && $0 > 0 }) else {
			throw SimFailure(description: "duration must be a positive number of seconds")
		}
		let fallback = durations.isEmpty ? 1 : durations.reduce(0, +) / Double(durations.count)
		var ordered = try proofs.map { name in
			(name: name, seconds: try timings.member(name).number ?? fallback)
		}
		if !durations.isEmpty {
			ordered.sort {
				$0.seconds != $1.seconds
					? $0.seconds > $1.seconds : $0.name.localeCompare($1.name) == .orderedAscending
			}
		}
		var shards = Array(repeating: Shard(), count: count)
		for proof in ordered {
			var best = 0
			for candidate in shards.indices
			where shards[candidate].estimatedSeconds < shards[best].estimatedSeconds {
				best = candidate
			}
			shards[best].proofs.append(proof.name)
			shards[best].estimatedSeconds += proof.seconds
		}
		return shards
	}

	static func summarize(_ tree: JSONValue, proofs: [String]) throws -> [ClassResult] {
		guard case .object = tree, case .array(let nodes) = try tree.member("testNodes") else {
			throw SimFailure(description: "test result has no testNodes")
		}
		var rows = proofs.map { ClassResult(name: $0) }
		func walk(_ node: JSONValue) throws {
			guard try node.member("nodeType").isString("Test Case") else {
				if case .array(let children) = try node.member("children") {
					for child in children { try walk(child) }
				}
				return
			}
			let identifier = try node.member("nodeIdentifier")
			let name = identifier.string.map { NodePath.segments($0)[0] }
			guard
				let row = rows.firstIndex(where: { row in
					name.map { row.name.hasSameUnits(as: $0) } ?? false
				})
			else {
				throw SimFailure(description: "unexpected test result \(identifier.interpolated)")
			}
			let result = try node.member("result")
			switch result.string {
			case "Passed": rows[row].passed += 1
			case "Failed": rows[row].failed += 1
			case "Skipped": rows[row].skipped += 1
			default: throw SimFailure(description: "unverified test result \(result.interpolated)")
			}
			guard let duration = try node.member("durationInSeconds").number, duration.isFinite,
				duration >= 0
			else {
				throw SimFailure(description: "missing duration for \(identifier.interpolated)")
			}
			rows[row].seconds += duration
		}
		for node in nodes { try walk(node) }
		for row in rows.indices {
			rows[row].missing = rows[row].passed + rows[row].failed + rows[row].skipped == 0 ? 1 : 0
		}
		return rows
	}
}
