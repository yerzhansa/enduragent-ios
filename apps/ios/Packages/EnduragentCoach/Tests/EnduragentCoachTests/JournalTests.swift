import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct JournalTests {
	static let day: Duration = .seconds(86_400)

	let directory: URL
	let file: URL
	let next: URL
	let clock = HeldClock()

	init() throws {
		directory = try TestTemporaryFolders.make()
		file = directory.appending(path: "diagnostics.jsonl")
		next = directory.appending(path: "diagnostics.jsonl.next")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	static func record(_ name: String, at: Date, padding: Int = 0) throws -> JournalRecord {
		try JournalRecord(
			StampedLine(
				at: at,
				line: .problem(
					ProblemLine(
						.skippedRecord, cause: ProblemCode("malformed"),
						row: SkippedRowText(
							kind: ScrubbedText(scrubbing: name),
							ulid: ScrubbedText(scrubbing: String(repeating: "x", count: padding)))))
			))
	}

	static func lines(_ records: [JournalRecord]) -> Data {
		records.reduce(into: Data()) { $0.append($1.encoded + Data("\n".utf8)) }
	}

	static func size(_ records: [JournalRecord]) -> Int {
		records.reduce(0) { $0 + $1.encoded.count + 1 }
	}

	func fileJournal() -> Journal {
		Journal(storage: FileJournalStorage(directory: directory), clock: clock)
	}

	@Test func anAppendedLineSurvivesANewJournal() throws {
		let line = try Self.record("first", at: clock.now)
		let journal = fileJournal()
		journal.append(line)
		#expect(try Data(contentsOf: file) == Self.lines([line]))
		let reopened = fileJournal()
		#expect(reopened.window(endingAt: clock.now) == [line.stamped])
		#expect(reopened.openings.isEmpty)
	}

	@Test func aTornLastLineIsDroppedAndTheFileRewritten() throws {
		let whole = try [Self.record("one", at: clock.now), Self.record("two", at: clock.now)]
		let torn = try Self.record("three", at: clock.now).encoded
		try (Self.lines(whole) + torn.prefix(torn.count / 2)).write(to: file)
		let journal = fileJournal()
		#expect(journal.openings == [.linesDropped(1)])
		#expect(try Data(contentsOf: file) == Self.lines(whole))
		#expect(journal.window(endingAt: clock.now) == whole.map(\.stamped))
	}

	@Test func anUnreadableFileRestartsTheJournal() throws {
		let storage = MemoryJournalStorage()
		try storage.append(Self.lines([Self.record("before", at: clock.now)]))
		storage.failReads()
		let journal = Journal(storage: storage, clock: clock)
		#expect(journal.openings == [.restarted(.unreadable)])
		#expect(journal.window(endingAt: clock.now).isEmpty)
		let line = try Self.record("after", at: clock.now)
		journal.append(line)
		#expect(storage.contents == Self.lines([line]))
		#expect(journal.health == .saving)
	}

	@Test func aFailedAppendStopsSavingUntilTheNextWrite() throws {
		let storage = MemoryJournalStorage()
		let journal = Journal(storage: storage, clock: clock)
		let first = try Self.record("first", at: clock.now)
		journal.append(first)
		clock.advance(by: .seconds(60))
		let failedAt = clock.now
		let lost = try Self.record("lost", at: failedAt)
		storage.failNextWrites(1)
		journal.append(lost)
		#expect(journal.health == .notSaving(since: failedAt, firstCause: .appendFailed))
		#expect(storage.contents == Self.lines([first]))
		clock.advance(by: .seconds(60))
		let alsoLost = try Self.record("also lost", at: clock.now)
		storage.failNextWrites(1)
		journal.append(alsoLost)
		#expect(journal.health == .notSaving(since: failedAt, firstCause: .appendFailed))
		clock.advance(by: .seconds(60))
		let saved = try Self.record("saved", at: clock.now)
		journal.append(saved)
		#expect(storage.contents == Self.lines([first, lost, alsoLost, saved]))
		#expect(journal.health == .saving)
	}

	@Test func aLeftoverNextIsDeletedAndTheOldFileKept() throws {
		let whole = try ["one", "two", "three"].map { try Self.record($0, at: clock.now) }
		try Self.lines(whole).write(to: file)
		let half = try Self.record("four", at: clock.now).encoded
		try half.prefix(half.count / 2).write(to: next)
		let journal = fileJournal()
		#expect(!FileManager.default.fileExists(atPath: next.path))
		#expect(journal.window(endingAt: clock.now) == whole.map(\.stamped))
		#expect(journal.openings.isEmpty)
		#expect(try Data(contentsOf: file) == Self.lines(whole))
	}

	@Test func openingPrunesByAgeAndSize() throws {
		let now = clock.now
		let old = try (0..<5).map {
			try Self.record("old \($0)", at: now - Double(15 * 86_400 + $0))
		}
		let recent = try (0..<600).map {
			try Self.record("recent \($0)", at: now - Double(600 - $0), padding: Scrub.limit)
		}
		#expect(Self.size(recent) > JournalPrune.byteLimit)
		let expected = JournalPrune.kept(old + recent, now: now)
		#expect(expected.count < recent.count)
		#expect(expected == Array(recent.suffix(expected.count)))
		try Self.lines(old + recent).write(to: file)
		let journal = fileJournal()
		#expect(journal.window(endingAt: now) == expected.map(\.stamped))
		#expect(try Data(contentsOf: file) == Self.lines(expected))
		#expect(journal.openings.isEmpty)
	}

	@Test func windowHoldsOnlyTheLast14Days() throws {
		let journal = Journal(storage: MemoryJournalStorage(), clock: clock)
		journal.append(try Self.record("first", at: clock.now))
		clock.advance(by: Self.day * 13)
		let second = try Self.record("second", at: clock.now)
		journal.append(second)
		let ahead = try Self.record("ahead", at: clock.now + Double(3 * 86_400))
		journal.append(ahead)
		clock.advance(by: Self.day + .seconds(1))
		#expect(journal.window(endingAt: clock.now) == [second.stamped, ahead.stamped])
	}

	@Test func aLongSessionStaysUnderOneMebibyte() throws {
		let journal = fileJournal()
		var appended: [JournalRecord] = []
		while Self.size(appended) <= 1_048_576 {
			let line = try Self.record(
				"line \(appended.count)", at: clock.now, padding: Scrub.limit)
			journal.append(line)
			appended.append(line)
		}
		let written = try Data(contentsOf: file)
		let lines = written.split(separator: UInt8(ascii: "\n")).map { Data($0) }
		#expect(written.count <= 786_432)
		#expect(lines.last == appended.last?.encoded)
		#expect(!lines.contains(appended[0].encoded))
	}
}
