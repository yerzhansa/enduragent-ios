import CryptoKit
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PlanFixtureProvenanceTests {
	static let otherRevision = "0000000000000000000000000000000000000000"

	@Test func committedFixturesMatchTheirManifestAndTheGenerator() throws {
		let copy = try FixtureCopy.committed()

		#expect(try copy.problems().isEmpty)
		let fixed = [
			"feasibility.json", "total-weeks.json", "sample-week.json", "tool-inputs.json",
			"tool-schemas.json", "headline.json", "plan-object.json",
		]
		#expect(Set(fixed).isSubset(of: copy.files.keys))
		#expect(try PlanFixtures.planDraftFiles().count == copy.files.count - fixed.count)
		#expect(try PlanFixtures.planDraftFiles().first == "plan-draft-1")
	}

	@Test func oneChangedFixtureByteIsADigestProblem() throws {
		var copy = try FixtureCopy.committed()
		try copy.replace("tool-schemas/0001", with: "tool-schemas/0009", in: "tool-schemas.json")

		#expect(try copy.problems() == [.digest("tool-schemas.json")])
	}

	@Test(arguments: PlanFixtures.generatorFiles)
	func generatorFileChangedWithoutANewRunIsAGeneratorProblem(file: String) throws {
		var copy = try FixtureCopy.committed()
		copy.generator[file]?.append(UInt8(ascii: "\n"))

		#expect(try copy.problems() == [.generator])
	}

	@Test func pinChangedInTheManifestOnlyIsARevisionProblem() throws {
		var copy = try FixtureCopy.committed()
		try copy.editManifest { $0["npmRevision"] = .string(Self.otherRevision) }

		#expect(try copy.problems() == [.revision(PlanFixtures.manifestFile)])
	}

	@Test func pinChangedInOneFixtureHeaderOnlyIsARevisionProblem() throws {
		var copy = try FixtureCopy.committed()
		try copy.replace(PlanFixtures.npmRevision, with: Self.otherRevision, in: "headline.json")
		try copy.rehash("headline.json")

		#expect(try copy.problems() == [.revision("headline.json")])
	}

	@Test func pinChangedEverywhereButTheLoaderIsARevisionProblemOfEveryFile() throws {
		var copy = try FixtureCopy.committed()
		for name in copy.files.keys {
			try copy.replace(PlanFixtures.npmRevision, with: Self.otherRevision, in: name)
			try copy.rehash(name)
		}
		try copy.editManifest { $0["npmRevision"] = .string(Self.otherRevision) }

		let expected = copy.files.keys.map(PlanFixtureProblem.revision)
		#expect(try copy.problems() == Set(expected + [.revision(PlanFixtures.manifestFile)]))
	}

	@Test func fixtureAddedWithoutTheManifestIsUnlisted() throws {
		var copy = try FixtureCopy.committed()
		copy.files["plan-draft-9.json"] = copy.files["plan-draft-1.json"]

		#expect(try copy.problems() == [.unlisted("plan-draft-9.json")])
	}

	@Test func fixtureRemovedWithoutTheManifestIsAbsent() throws {
		var copy = try FixtureCopy.committed()
		copy.files["headline.json"] = nil

		#expect(try copy.problems() == [.absent("headline.json")])
	}

	@Test func decodedCaseCountThatDiffersFromTheManifestIsACountProblem() throws {
		var copy = try FixtureCopy.committed()
		try copy.editFile("tool-schemas.json") { $0["cases"] = .number(4) }

		#expect(try copy.problems() == [.caseCount("tool-schemas.json")])
	}

	@Test func toolCountThatDiffersFromTheManifestIsACountProblem() throws {
		var copy = try FixtureCopy.committed()
		try copy.editFile("tool-inputs.json") { entry in
			var byTool = entry["casesByTool"]?.objectFields ?? [:]
			byTool["plan_load"] = .number((byTool["plan_load"]?.numberValue ?? 0) + 1)
			byTool["plan_save"] = .number((byTool["plan_save"]?.numberValue ?? 0) - 1)
			entry["casesByTool"] = .object(byTool)
		}

		#expect(try copy.problems() == [.caseCount("tool-inputs.json")])
	}

	@Test func rehashedFixtureWhoseToolsNoLongerMatchTheManifestIsACountProblem() throws {
		var copy = try FixtureCopy.committed()
		try #require(try copy.problems().isEmpty)
		try copy.replace(
			#""tool":"plan_load""#, with: #""tool":"plan_save""#, in: "tool-inputs.json")
		try copy.rehash("tool-inputs.json")

		#expect(try copy.problems() == [.caseCount("tool-inputs.json")])
	}

	@Test func fixtureWithNoCasesIsACountProblemEvenWhenTheManifestAgrees() throws {
		var copy = try FixtureCopy.committed()
		let empty =
			#"{"npmRevision":"\#(PlanFixtures.npmRevision)","function":"toolSchemas","cases":[]}"#
		copy.files["tool-schemas.json"] = Data((empty + "\n").utf8)
		try copy.rehash("tool-schemas.json")
		try copy.editFile("tool-schemas.json") { $0["cases"] = .number(0) }

		#expect(try copy.problems().contains(.caseCount("tool-schemas.json")))
	}

	@Test func twoCasesOnOneLineIsALayoutProblem() throws {
		var copy = try FixtureCopy.committed()
		try copy.replace(
			"},\n{\"id\":\"tool-schemas/0002\"", with: "},{\"id\":\"tool-schemas/0002\"",
			in: "tool-schemas.json")
		try copy.rehash("tool-schemas.json")

		#expect(try copy.problems() == [.layout("tool-schemas.json")])
	}

	@Test func fixtureThatReachesTheSizeCapIsALayoutProblem() throws {
		var copy = try FixtureCopy.committed()
		let size = try #require(copy.files["headline.json"]).count
		let padding = String(repeating: " ", count: PlanFixtures.sizeCap - size)
		try copy.replace("\n]}\n", with: padding + "\n]}\n", in: "headline.json")
		try copy.rehash("headline.json")

		#expect(try #require(copy.files["headline.json"]).count == PlanFixtures.sizeCap)
		#expect(try copy.problems() == [.layout("headline.json")])
	}

	@Test func everyDatedCaseCarriesItsClockAndTheZonesFallOnBothSidesOfTheUTCDay() throws {
		let files = ["total-weeks"] + (try PlanFixtures.planDraftFiles())
		var compared = 0
		var before = 0
		var after = 0
		var missing: [String] = []
		for file in files {
			for item in try PlanFixtures.cases(file) {
				compared += 1
				guard let instant = item.instant, let today = item.today, item.timeZone != nil,
					let weekday = item.weekday, Self.weekdays.contains(weekday)
				else {
					missing.append(item.id)
					continue
				}
				let utcDay = CivilDate(date: instant, timeZone: .gmt)
				if today < utcDay { before += 1 }
				if today > utcDay { after += 1 }
			}
		}

		#expect(missing.isEmpty, "\(missing.count) cases lack a clock: \(missing.prefix(3))")
		#expect(before > 0)
		#expect(after > 0)
		#expect(compared == (try PlanFixtures.manifestCount(files)))
		#expect(compared > 0)
	}

	static let weekdays: Set<String> = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
}

private struct FixtureCopy {
	var manifest: Data
	var files: [String: Data]
	var generator: [String: Data]

	static func committed() throws -> FixtureCopy {
		FixtureCopy(
			manifest: try PlanFixtures.bundledFile(PlanFixtures.manifestFile),
			files: try PlanFixtures.bundledFiles(),
			generator: try PlanFixtures.generatorSources())
	}

	func problems() throws -> Set<PlanFixtureProblem> {
		Set(
			try PlanFixtureProvenance.problems(
				manifest: manifest, files: files, generator: generator))
	}

	mutating func replace(_ old: String, with new: String, in name: String) throws {
		let text = String(decoding: try #require(files[name]), as: UTF8.self)
		let range = try #require(text.range(of: old), "\(name) does not hold \(old)")
		files[name] = Data(text.replacingCharacters(in: range, with: new).utf8)
	}

	mutating func rehash(_ name: String) throws {
		let digest = SHA256.hash(data: try #require(files[name]))
		let hex = digest.map { String(format: "%02x", $0) }.joined()
		try editFile(name) { $0["sha256"] = .string(hex) }
	}

	mutating func editFile(_ name: String, _ change: (inout [String: JSONValue]) -> Void) throws {
		try editManifest { record in
			var listed = record["files"]?.objectFields ?? [:]
			var entry = listed[name]?.objectFields ?? [:]
			change(&entry)
			listed[name] = .object(entry)
			record["files"] = .object(listed)
		}
	}

	mutating func editManifest(_ change: (inout [String: JSONValue]) -> Void) throws {
		var record = try JSONValue.parse(String(decoding: manifest, as: UTF8.self)).objectFields
		change(&record)
		manifest = Data(canonicalJSON(.object(record)).utf8)
	}
}
