import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct JournalPruneTests {
	static let now = Date(timeIntervalSince1970: 1_793_092_443)
	static let day: TimeInterval = 86_400

	static func record(at: Date, text: String = "userMessage") throws -> JournalRecord {
		try JournalRecord(
			StampedLine(
				at: at,
				line: .problem(
					ProblemLine(
						.skippedRecord, cause: ProblemCode("malformed"),
						row: SkippedRowText(
							kind: ScrubbedText(scrubbing: text),
							ulid: ScrubbedText(scrubbing: "row"))))))
	}

	static func bytes(_ records: [JournalRecord]) -> Int {
		records.reduce(0) { $0 + $1.encoded.count + 1 }
	}

	@Test func linesOlderThanFourteenDaysByTheirOwnTimeAreDroppedAndLaterLinesKept() throws {
		let records = try [
			Self.record(at: Self.now - 14 * Self.day - 1),
			Self.record(at: Self.now - 14 * Self.day),
			Self.record(at: Self.now - Self.day),
			Self.record(at: Self.now + 3 * Self.day),
			Self.record(at: Self.now - 40 * Self.day),
		]
		let kept = JournalPrune.kept(records, now: Self.now)
		#expect(kept == [records[1], records[2], records[3]])
	}

	@Test func aLogOverOneMiBLosesItsOldestLinesUntilItIsAtMost768KiB() throws {
		let large = String(repeating: "x", count: Scrub.limit)
		let records = try (0..<3_350).map {
			try Self.record(
				at: Self.now - Double(3_350 - $0), text: $0 < 350 ? large : "userMessage")
		}
		#expect(Self.bytes(records) > 1_048_576)
		#expect(records[0].encoded.count > 10 * records[3_349].encoded.count)
		let kept = JournalPrune.kept(records, now: Self.now)
		#expect(Array(records.suffix(kept.count)) == kept)
		#expect(Self.bytes(kept) <= 786_432)
		#expect(Self.bytes(records.suffix(kept.count + 1)) > 786_432)
	}

	@Test func aLogAtOneMiBIsKeptWhole() throws {
		let text = String(repeating: "x", count: Scrub.limit)
		let size = try Self.bytes([Self.record(at: Self.now, text: text)])
		let records = try (0..<(1_048_576 / size)).map {
			try Self.record(at: Self.now - Double($0), text: text)
		}
		#expect(Self.bytes(records) > 786_432)
		#expect(Self.bytes(records) <= 1_048_576)
		#expect(JournalPrune.kept(records, now: Self.now) == records)
	}
}
