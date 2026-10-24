import CryptoKit
import Foundation
import Synchronization

@testable import EnduragentCoach

enum PlanFixtures {
	static let npmRevision = "d192cb974e715e1527645e0acf0d8353ed4d0edc"
	static let generatorFiles = ["run.mjs", "freeze.mts", "generate.mts", "cases.mts"]
	static let manifestFile = "manifest.json"
	static let sizeCap = 4_000_000

	struct Case: Sendable {
		let id: String
		let tool: String?
		let input: JSONValue
		let output: JSONValue?
		let thrown: JSONValue?
		let instant: Date?
		let timeZone: TimeZone?
		let today: CivilDate?
		let weekday: String?
	}

	static func cases(_ file: String) throws -> [Case] {
		try cases(in: try bundledFile(file + ".json"))
	}

	static func cases(in data: Data) throws -> [Case] {
		try casesByText.withLock { known in
			if let cases = known[data] { return cases }
			let document = try JSONValue.parse(String(decoding: data, as: UTF8.self))
			guard let rows = document.objectFields["cases"]?.arrayValue else {
				throw PlanFixtureFailure(description: "the fixture has no cases array")
			}
			let cases = try rows.map(Case.init(row:))
			known[data] = cases
			return cases
		}
	}

	private static let casesByText = Mutex<[Data: [Case]]>([:])

	static func numberTokens(_ file: String) throws -> [[String]] {
		var scanner = OutputNumberScanner(bytes: Array(try bundledFile(file + ".json")))
		try scanner.document()
		return scanner.cases
	}

	static func manifest() throws -> JSONValue {
		try JSONValue.parse(String(decoding: try bundledFile(manifestFile), as: UTF8.self))
	}

	static func manifestCount(_ files: [String]) throws -> Int {
		let listed = try manifest().objectFields["files"]?.objectFields ?? [:]
		return try files.reduce(0) { total, file in
			guard let count = listed[file + ".json"]?.objectFields["cases"]?.intValue() else {
				throw PlanFixtureFailure(description: "the manifest has no case count for \(file)")
			}
			return total + count
		}
	}

	static func planDraftFiles() throws -> [String] {
		let listed = try manifest().objectFields["files"]?.objectFields ?? [:]
		return listed.keys.filter { $0.hasPrefix("plan-draft-") }
			.map { String($0.dropLast(".json".count)) }
			.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
	}

	static func bundledFiles() throws -> [String: Data] {
		guard
			let folder = Bundle.module.url(
				forResource: "plan", withExtension: nil, subdirectory: "Fixtures")
		else {
			throw PlanFixtureFailure(description: "the test bundle has no Fixtures/plan folder")
		}
		var files: [String: Data] = [:]
		for url in try FileManager.default.contentsOfDirectory(
			at: folder, includingPropertiesForKeys: nil)
		where url.lastPathComponent != manifestFile {
			files[url.lastPathComponent] = try Data(contentsOf: url)
		}
		return files
	}

	static func bundledFile(_ name: String) throws -> Data {
		guard
			let url = Bundle.module.url(
				forResource: name, withExtension: nil, subdirectory: "Fixtures/plan")
		else {
			throw PlanFixtureFailure(description: "the test bundle has no Fixtures/plan/\(name)")
		}
		return try Data(contentsOf: url)
	}

	static func generatorSources(from file: String = #filePath) throws -> [String: Data] {
		let folder = try repositoryRoot(from: file).appending(path: "tools/npm-fixtures")
		var sources: [String: Data] = [:]
		for name in generatorFiles {
			sources[name] = try Data(contentsOf: folder.appending(path: name))
		}
		return sources
	}

	private static func repositoryRoot(from file: String) throws -> URL {
		var folder = URL(filePath: file).deletingLastPathComponent()
		for _ in folder.pathComponents {
			if FileManager.default.fileExists(atPath: folder.appending(path: "Makefile").path) {
				return folder
			}
			folder.deleteLastPathComponent()
		}
		throw PlanFixtureFailure(description: "no folder above \(file) holds a Makefile")
	}
}

extension PlanFixtures.Case {
	init(row: JSONValue) throws {
		let fields = row.objectFields
		guard let id = fields["id"]?.stringValue, let input = fields["input"] else {
			throw PlanFixtureFailure(description: "a case has no id or input")
		}
		self.id = id
		self.input = input
		tool = fields["tool"]?.stringValue
		output = fields["output"]
		thrown = fields["thrown"]
		weekday = fields["weekday"]?.stringValue
		instant = try fields["instant"].map { value in
			try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
				.parse(try Self.text(value, in: id))
		}
		timeZone = try fields["timeZone"].map { value in
			guard let zone = TimeZone(identifier: try Self.text(value, in: id)) else {
				throw PlanFixtureFailure(description: "\(id) names an unknown time zone")
			}
			return zone
		}
		today = try fields["today"].map { value in
			guard let day = CivilDate(rawValue: try Self.text(value, in: id)) else {
				throw PlanFixtureFailure(description: "\(id) has a today that is not a day")
			}
			return day
		}
	}

	private static func text(_ value: JSONValue, in id: String) throws -> String {
		guard let text = value.stringValue else {
			throw PlanFixtureFailure(description: "\(id) holds a clock field that is not text")
		}
		return text
	}
}

enum PlanFixtureProblem: Hashable, Sendable {
	case revision(String)
	case unlisted(String)
	case absent(String)
	case digest(String)
	case caseCount(String)
	case layout(String)
	case generator
}

enum PlanFixtureProvenance {
	static func problems(manifest: Data, files: [String: Data], generator: [String: Data]) throws
		-> [PlanFixtureProblem]
	{
		let record = try JSONValue.parse(String(decoding: manifest, as: UTF8.self)).objectFields
		var found: [PlanFixtureProblem] = []
		if record["npmRevision"]?.stringValue != PlanFixtures.npmRevision {
			found.append(.revision(PlanFixtures.manifestFile))
		}
		let listed = record["files"]?.objectFields ?? [:]
		for name in files.keys.sorted() where listed[name] == nil {
			found.append(.unlisted(name))
		}
		for name in listed.keys.sorted() {
			guard let bytes = files[name] else {
				found.append(.absent(name))
				continue
			}
			found += try problems(of: name, bytes, listed: listed[name]?.objectFields ?? [:])
		}
		if generatorDigest(generator) != record["generatorSHA256"]?.stringValue {
			found.append(.generator)
		}
		return found
	}

	private static func problems(of name: String, _ bytes: Data, listed: [String: JSONValue])
		throws -> [PlanFixtureProblem]
	{
		var found: [PlanFixtureProblem] = []
		let header = #"{"npmRevision":"\#(PlanFixtures.npmRevision)","#
		if !bytes.starts(with: Data(header.utf8)) { found.append(.revision(name)) }
		if hex(SHA256.hash(data: bytes)) != listed["sha256"]?.stringValue {
			found.append(.digest(name))
		}
		let cases = try PlanFixtures.cases(in: bytes)
		if cases.isEmpty || listed["cases"]?.intValue() != cases.count
			|| !toolCounts(cases, match: listed["casesByTool"])
		{
			found.append(.caseCount(name))
		}
		let lines = bytes.count { $0 == UInt8(ascii: "\n") }
		if lines != cases.count + 2 || bytes.count >= PlanFixtures.sizeCap {
			found.append(.layout(name))
		}
		return found
	}

	private static func toolCounts(_ cases: [PlanFixtures.Case], match recorded: JSONValue?)
		-> Bool
	{
		guard let recorded else { return true }
		var counted: [String: Int] = [:]
		for item in cases {
			counted[item.tool ?? "", default: 0] += 1
		}
		return recorded.objectFields.mapValues { $0.intValue() } == counted.mapValues(Optional.some)
	}

	private static func generatorDigest(_ generator: [String: Data]) -> String? {
		var joined = Data()
		for name in PlanFixtures.generatorFiles {
			guard let bytes = generator[name] else { return nil }
			joined.append(bytes)
		}
		return hex(SHA256.hash(data: joined))
	}

	private static func hex(_ digest: SHA256.Digest) -> String {
		digest.map { String(format: "%02x", $0) }.joined()
	}
}

struct PlanFixtureFailure: Error, CustomStringConvertible {
	let description: String
}
