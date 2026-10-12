import EnduragentCoachFixtures
import Foundation
import Testing

@Suite struct TestTemporaryFoldersTests {
	@Test func firstUseRemovesEndedProcessFolders() throws {
		let parent = try parentDirectory()
		let ended = try endedFolder(in: parent)
		let next = try TestTemporaryFolders(parent: parent)
		let directory = next.nextDirectory()
		#expect(!FileManager.default.fileExists(atPath: ended.path))
		#expect(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
	}

	@Test func firstUsePreservesLiveProcessFolders() throws {
		let parent = try parentDirectory()
		let ended = try endedFolder(in: parent)
		let live = try TestTemporaryFolders(parent: parent)
		let directory = live.nextDirectory()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
		let payload = directory.appending(path: "store")
		try Data("live store".utf8).write(to: payload)
		let next = try TestTemporaryFolders(parent: parent)
		_ = next.nextDirectory()
		try withExtendedLifetime(live) {
			let contents = try Data(contentsOf: payload)
			#expect(contents == Data("live store".utf8))
			#expect(!FileManager.default.fileExists(atPath: ended.path))
		}
	}

	@Test func firstUsePreservesFoldersWithoutAnOwnershipMarker() throws {
		let parent = try parentDirectory()
		let unowned = parent.appending(
			path: "enduragent-test-process-123-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: false)
		let payload = unowned.appending(path: "store")
		try Data("unowned store".utf8).write(to: payload)
		let next = try TestTemporaryFolders(parent: parent)
		_ = next.nextDirectory()
		#expect(try Data(contentsOf: payload) == Data("unowned store".utf8))
	}

	@Test func firstUsePreservesFoldersWithAnInvalidOwnershipMarker() throws {
		let parent = try parentDirectory()
		let unowned = parent.appending(
			path: "enduragent-test-process-123-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: false)
		let marker = parent.appending(path: ".\(unowned.lastPathComponent).owner")
		try Data("another owner".utf8).write(to: marker)
		let next = try TestTemporaryFolders(parent: parent)
		_ = next.nextDirectory()
		#expect(try Data(contentsOf: marker) == Data("another owner".utf8))
	}

	@Test func firstUseDoesNotFollowRootOrMarkerSymlinks() throws {
		let parent = try parentDirectory()
		let outside = try parentDirectory()
		let ended = try endedFolder(in: outside)
		let link = parent.appending(path: ended.lastPathComponent)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ended)
		let unowned = parent.appending(
			path: "enduragent-test-process-123-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: false)
		try FileManager.default.createSymbolicLink(
			at: parent.appending(path: ".\(unowned.lastPathComponent).owner"),
			withDestinationURL: outside.appending(path: ".\(ended.lastPathComponent).owner"))
		let next = try TestTemporaryFolders(parent: parent)
		_ = next.nextDirectory()
		#expect(FileManager.default.fileExists(atPath: ended.path))
		#expect(FileManager.default.fileExists(atPath: link.path))
		#expect(FileManager.default.fileExists(atPath: unowned.path))
	}

	@Test(.timeLimit(.minutes(1)))
	func simultaneousFirstUsesPreserveEveryLiveRoot() async throws {
		let parent = try parentDirectory()
		let owners = try await withThrowingTaskGroup(of: TestTemporaryFolders.self) { group in
			for _ in 0..<12 {
				group.addTask { try TestTemporaryFolders(parent: parent) }
			}
			var owners: [TestTemporaryFolders] = []
			for try await owner in group { owners.append(owner) }
			return owners
		}
		let folders = owners.map { $0.nextDirectory().deletingLastPathComponent() }
		#expect(Set(folders).count == 12)
		withExtendedLifetime(owners) {
			for folder in folders {
				#expect(FileManager.default.fileExists(atPath: folder.path))
			}
		}
	}

	private func parentDirectory() throws -> URL {
		let parent = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
		return parent
	}

	private func endedFolder(in parent: URL) throws -> URL {
		let ended = try TestTemporaryFolders(parent: parent)
		let directory = ended.nextDirectory()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
		try Data("ended store".utf8).write(to: directory.appending(path: "store"))
		return directory.deletingLastPathComponent()
	}
}
