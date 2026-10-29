import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ShareFolderTests {
	static let name = "enduragent-diagnostics-2026-10-27-0914.json"

	let temporary: URL
	let folder: ShareFolder

	init() throws {
		temporary = try TestTemporaryFolders.make()
		folder = ShareFolder(in: temporary)
	}

	func contents() throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: folder.directory.path).sorted()
	}

	@Test func eachFileIsNamedWithItsHandlesIdUnderTheShareFolder() throws {
		let first = try folder.write(Data("first".utf8), named: Self.name, id: fixedUlid(1))
		let second = try folder.write(Data("second".utf8), named: Self.name, id: fixedUlid(2))
		#expect(folder.directory.lastPathComponent == "EnduragentDiagnostics")
		#expect(folder.directory.deletingLastPathComponent().path == temporary.path)
		#expect(first.id == fixedUlid(1))
		#expect(
			first.url.path
				== folder.directory.appending(path: "\(fixedUlid(1).rawValue)/\(Self.name)").path)
		#expect(second.url.deletingLastPathComponent().lastPathComponent == fixedUlid(2).rawValue)
		#expect(try contents() == [fixedUlid(1).rawValue, fixedUlid(2).rawValue].sorted())
		try folder.remove(first)
		#expect(try contents() == [fixedUlid(2).rawValue])
		#expect(try Data(contentsOf: second.url) == Data("second".utf8))
	}

	@Test func sweepRemovesEveryFileInTheFolder() throws {
		try folder.sweep()
		_ = try folder.write(Data("left".utf8), named: Self.name, id: fixedUlid(3))
		_ = try folder.write(Data("left".utf8), named: Self.name, id: fixedUlid(4))
		try Data("stray".utf8).write(to: folder.directory.appending(path: "stray.json"))
		try folder.sweep()
		#expect(try contents().isEmpty)
	}
}
