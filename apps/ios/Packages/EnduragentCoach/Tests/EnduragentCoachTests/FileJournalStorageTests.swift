import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FileJournalStorageTests {
	let directory: URL
	let storage: FileJournalStorage
	let journal: URL
	let next: URL

	init() throws {
		directory = try TestTemporaryFolders.make()
		storage = FileJournalStorage(directory: directory)
		journal = directory.appending(path: "diagnostics.jsonl")
		next = directory.appending(path: "diagnostics.jsonl.next")
	}

	@Test func replaceRenamesTheNextFileOverTheJournal() throws {
		try storage.append(Data("old\n".utf8))
		try storage.replace(with: Data("new\n".utf8))
		#expect(try Data(contentsOf: journal) == Data("new\n".utf8))
		#expect(!FileManager.default.fileExists(atPath: next.path))
	}

	@Test func aReplaceThatCannotWriteTheNextFileLeavesTheJournalAsItWas() throws {
		try storage.append(Data("old\n".utf8))
		try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
		#expect(throws: CocoaError.self) { try storage.replace(with: Data("new\n".utf8)) }
		#expect(try storage.read() == Data("old\n".utf8))
	}

	@Test func removeLeftoverDeletesANextFileAndAcceptsNone() throws {
		try storage.append(Data("kept\n".utf8))
		try Data("torn".utf8).write(to: next)
		try storage.removeLeftover()
		#expect(!FileManager.default.fileExists(atPath: next.path))
		try storage.removeLeftover()
		#expect(try storage.read() == Data("kept\n".utf8))
	}

	@Test func readingAMissingJournalIsNil() throws {
		#expect(try storage.read() == nil)
	}

	@Test func appendCreatesTheJournalAndAddsToItsEnd() throws {
		try storage.append(Data("one\n".utf8))
		try storage.append(Data("two\n".utf8))
		#expect(try Data(contentsOf: journal) == Data("one\ntwo\n".utf8))
	}
}
