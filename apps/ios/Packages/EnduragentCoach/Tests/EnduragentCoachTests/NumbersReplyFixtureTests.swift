import EnduragentCoach
import EnduragentCoachFixtures
import Testing

@Suite struct NumbersReplyFixtureTests {
	@Test func theNumbersReplyHoldsALongSummaryTableAndALapTableWithEmptyCells() throws {
		let tables = try tables(NumbersReplyFixture.source)
		try #require(tables.count == 2)
		let summary = tables[0].rowDescriptions.map(\.parts)
		#expect(tables[0].layout == .stacked)
		#expect(summary.count >= 12)
		#expect(summary.allSatisfy { $0.count == 2 })
		#expect(summary.contains(["Start", "1998-03-14 07:42"]))
		#expect(summary.contains(["Calories", "unavailable"]))
		#expect(summary.contains(["Decoupling", "−1.4 %"]))
		let laps = tables[1].rowDescriptions.map(\.parts)
		#expect(tables[1].layout == .grid)
		#expect(tables[1].columns.elements.count == 5)
		#expect(laps.count >= 8)
		#expect(laps.filter { $0.count == 8 }.count == 2)
		#expect(laps.filter { $0.count == 10 }.count == laps.count - 2)
		#expect(
			laps[3] == [
				"Lap", "Interval 2", "Elapsed time", "10 min 00 s", "Distance", "5.18 km",
				"Average heart rate", "161 bpm",
			])
	}

	@Test func theHeldReplyStopsAfterTheSummaryTableAndThreeLapRows() throws {
		let whole = try tables(NumbersReplyFixture.source)
		let held = try tables(NumbersReplyFixture.held)
		try #require(held.count == 2)
		#expect(NumbersReplyFixture.source.hasPrefix(NumbersReplyFixture.held))
		#expect(held[0] == whole[0])
		#expect(held[1].headerDescription == whole[1].headerDescription)
		#expect(held[1].rowDescriptions == Array(whole[1].rowDescriptions.prefix(3)))
	}

	@Test func aLapRowThatHasPartlyArrivedIsReadUnderItsOwnHeaders() throws {
		let source = NumbersReplyFixture.source
		let whole = try tables(source)[1].rowDescriptions.map(Self.valuesByHeader)
		let arriving = try #require(source.range(of: NumbersReplyFixture.laterLaps))
		var partlyArrivedRows = 0
		for end in source[arriving].indices {
			let arrived = try tables(String(source[..<end]))
			try #require(arrived.count == 2)
			let rows = arrived[1].rowDescriptions.map(Self.valuesByHeader)
			try #require(rows.count <= whole.count)
			for (row, complete) in zip(rows, whole) where row != complete {
				partlyArrivedRows += 1
				for (header, value) in row {
					#expect(complete[header]?.hasPrefix(value) == true)
				}
			}
		}
		#expect(partlyArrivedRows > 100)
	}

	private static func valuesByHeader(_ row: ReplyRowDescription) -> [String: String] {
		var values: [String: String] = [:]
		for index in stride(from: 0, to: row.parts.count - 1, by: 2) {
			values[row.parts[index]] = row.parts[index + 1]
		}
		return values
	}

	private func tables(_ source: String) throws -> [ReplyTable] {
		guard case .blocks(let blocks) = ReplyParser.foundation.document(source) else {
			Issue.record("Expected a formatted document")
			return []
		}
		return blocks.compactMap { block in
			if case .table(let table) = block { return table }
			return nil
		}
	}
}
