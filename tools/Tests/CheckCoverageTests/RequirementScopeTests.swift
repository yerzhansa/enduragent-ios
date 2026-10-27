import Testing

@testable import CheckCoverage

struct RequirementScopeTests {
	@Test(.timeLimit(.minutes(1)))
	func milestoneSixScopeIsTheRetainedIdsOfMilestoneSixAndTheDifferencesOfADR0085() throws {
		let scope = try #require(
			try RequirementScope.of(
				table: "coverage/milestone-6.json", retained: RetainedTests.committed()))
		#expect(scope.listed == RequirementCase.sixListed)
		#expect(scope.agreedDifferences == RequirementCase.sixAgreed)
		#expect(scope.decisionRecords == ["ADR-0085"])
		#expect(scope.parts.isEmpty)
	}

	@Test(.timeLimit(.minutes(1)))
	func milestoneSixTableWithoutTheRetainedListCannotBeRead() throws {
		let result = try Scratch(files: [
			"coverage/milestone-6.json": #"""
			{"units": {"1.1": 1}, "criteria": [{"id": "1.1.1", "statement": "S.", "noAutomatedProof": "T."}],
			"requirements": [],
			"plan": {"units": {"1.1": 1}, "requirements": {}}, "open": []}
			"""#
		]).runCommand(tables: ["coverage/milestone-6.json"])
		#expect(result.status == 2)
		#expect(
			result.errors == [
				"check-coverage: coverage/milestone-6.json could not be read: "
					+ "coverage/milestone-6.json is checked against coverage/spec/retained.json, "
					+ "which does not exist"
			])
	}

	@Test(.timeLimit(.minutes(1)))
	func agreedDifferencePlacesAsAPartThoughItsParentIsNotListed() throws {
		let scope = RequirementScope.milestoneSix(try RetainedTests.committed())
		#expect(scope.place(of: "B11/three-outcomes") == .success(.part))
		#expect(scope.place(of: "G09/no-refresh") == .success(.part))
		#expect(scope.place(of: "B11/other") == .failure(.unknownParent))
		#expect(scope.place(of: "G09/refresh") == .failure(.unknownParent))
	}
}
