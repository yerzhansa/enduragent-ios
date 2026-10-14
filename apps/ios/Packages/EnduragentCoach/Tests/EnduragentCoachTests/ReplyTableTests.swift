import Testing

@testable import EnduragentCoach

@Suite struct ReplyTableTests {
	private static let summary = """
		| Metric | Value |
		| :--- | ---: |
		| **Start** | 2026-10-11 07:42 |
		| Distance | 42,5 km |
		| Average power | `238 W` |
		| Elevation change | −120 m |
		| Decoupling | -0.4 % |
		| Average heart rate | unavailable |
		| | 1:23:45 |
		| Notes | |
		"""

	private static let laps = """
		| Lap | Time | Distance | Power | Heart rate |
		| ---: | ---: | ---: | ---: | ---: |
		| 1 | 5:02 | 2,61 km | 240 W | 148 bpm |
		| 2 | 4:58 | 2,60 km | | 151 bpm |
		| 3 | 5:10 | | *unavailable* | |
		| | | | | |
		| 5 | 4:49 | 2,71 km | 255 W | ~~160~~ 158 bpm |
		"""

	@Test(arguments: [
		("| Metric | Value |\n|---|---|\n| Load | 82 |", ReplyTableLayout.stacked),
		("| Metric |\n|---|\n| Load |", .grid),
		("| Day | Load | Note |\n|---|---|---|\n| Tue | 48 | easy |", .grid),
		(laps, .grid),
	]) func onlyATwoColumnTableStacks(source: String, layout: ReplyTableLayout) throws {
		#expect(try table(source).layout == layout)
	}

	@Test func stackedRowsReadTheMetricThenItsValueInSourceOrder() throws {
		let table = try table(Self.summary)
		#expect(table.headerDescription.parts == ["Metric", "Value"])
		#expect(
			table.rowDescriptions.map(\.parts) == [
				["Start", "2026-10-11 07:42"],
				["Distance", "42,5 km"],
				["Average power", "238 W"],
				["Elevation change", "−120 m"],
				["Decoupling", "-0.4 %"],
				["Average heart rate", "unavailable"],
				["1:23:45"],
				["Notes"],
			])
	}

	@Test func gridRowsReadEachCellAfterItsOwnHeaderAndSkipEmptyCells() throws {
		let table = try table(Self.laps)
		#expect(
			table.headerDescription.parts == ["Lap", "Time", "Distance", "Power", "Heart rate"])
		#expect(
			table.rowDescriptions.map(\.parts) == [
				[
					"Lap", "1", "Time", "5:02", "Distance", "2,61 km", "Power", "240 W",
					"Heart rate", "148 bpm",
				],
				["Lap", "2", "Time", "4:58", "Distance", "2,60 km", "Heart rate", "151 bpm"],
				["Lap", "3", "Time", "5:10", "Power", "unavailable"],
				[],
				[
					"Lap", "5", "Time", "4:49", "Distance", "2,71 km", "Power", "255 W",
					"Heart rate", "160 158 bpm",
				],
			])
	}

	@Test func aCellUnderAnEmptyHeaderIsReadWithoutBorrowingAnotherHeader() throws {
		let table = try table("| Lap | | Power |\n|---|---|---|\n| 1 | warm-up | 180 W |")
		#expect(table.headerDescription.parts == ["Lap", "Power"])
		#expect(table.rowDescriptions.map(\.parts) == [["Lap", "1", "warm-up", "Power", "180 W"]])
	}

	@Test func theSpokenTableIsItsRowDescriptionsLineByLine() throws {
		let document = ReplyParser.foundation.document(Self.laps)
		let table = try table(Self.laps)
		#expect(
			table.rowDescriptions.map(\.accessibilityText) == [
				"Lap, 1, Time, 5:02, Distance, 2,61 km, Power, 240 W, Heart rate, 148 bpm",
				"Lap, 2, Time, 4:58, Distance, 2,60 km, Heart rate, 151 bpm",
				"Lap, 3, Time, 5:10, Power, unavailable",
				"",
				"Lap, 5, Time, 4:49, Distance, 2,71 km, Power, 255 W, Heart rate, 160 158 bpm",
			])
		#expect(
			document.accessibilityText
				== """
				Lap, Time, Distance, Power, Heart rate
				Lap, 1, Time, 5:02, Distance, 2,61 km, Power, 240 W, Heart rate, 148 bpm
				Lap, 2, Time, 4:58, Distance, 2,60 km, Heart rate, 151 bpm
				Lap, 3, Time, 5:10, Power, unavailable
				Lap, 5, Time, 4:49, Distance, 2,71 km, Power, 255 W, Heart rate, 160 158 bpm
				""")
		#expect(
			ReplyParser.foundation.document(Self.summary).accessibilityText.hasPrefix(
				"Metric, Value\nStart, 2026-10-11 07:42\nDistance, 42,5 km\n"))
	}

	@Test func aGridRowOffersEveryLinkInItsOwnCellsInSourceOrder() throws {
		let table = try table(
			"""
			| Day | Workout | Notes |
			|---|---|---|
			| Tue | [Tempo **run**](https://example.com/tempo) | see [plan](https://example.com/plan) |
			| Wed | Rest | |
			| Thu | [Long ride](https://example.com/long) | |
			""")
		#expect(table.headerDescription.links.isEmpty)
		#expect(
			table.rowDescriptions.map { $0.links.map(\.label) } == [
				["Tempo run", "plan"], [], ["Long ride"],
			])
		#expect(
			table.rowDescriptions.map { $0.links.map(\.target.url.absoluteString) } == [
				["https://example.com/tempo", "https://example.com/plan"], [],
				["https://example.com/long"],
			])
		#expect(
			table.rowDescriptions.first?.accessibilityText
				== "Day, Tue, Workout, Tempo run, Notes, see plan")
	}

	@Test func aStackedTableOffersTheLinksOfItsHeaderAndOfEachRow() throws {
		let table = try table(
			"""
			| Metric | [Source](https://example.com/source) |
			|---|---|
			| [Load](https://example.com/load) | 82 |
			| Ramp | 4 |
			""")
		#expect(table.layout == .stacked)
		#expect(table.headerDescription.links.map(\.label) == ["Source"])
		#expect(
			table.headerDescription.links.map(\.target.url.absoluteString)
				== ["https://example.com/source"])
		#expect(table.rowDescriptions.map { $0.links.map(\.label) } == [["Load"], []])
		#expect(
			table.rowDescriptions.map { $0.links.map(\.target.url.absoluteString) }
				== [["https://example.com/load"], []])
	}

	private func table(_ source: String) throws -> ReplyTable {
		guard case .blocks(let blocks) = ReplyParser.foundation.document(source),
			case .table(let table) = blocks.first
		else {
			Issue.record("Expected a table for \(source.prefix(80))")
			throw ReplyParseFailure.documentStructure
		}
		return table
	}
}
