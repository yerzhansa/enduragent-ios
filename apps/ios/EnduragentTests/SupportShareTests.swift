import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct SupportShareTests {
	private let harness = FixtureLaunchTests()

	@Test func eachShareCompletionShowsItsLine() async throws {
		let cases: [(activity: String?, completed: Bool, fails: Bool, sentence: String)] = [
			("com.apple.DocumentManagerUICore.SaveToFiles", true, false, "Saved to Files."),
			(
				"com.apple.UIKit.activity.AirDrop", true, false,
				"Shared. iOS handed the file to the app you chose."
			),
			(nil, false, false, "Canceled. The file was not shared."),
			(nil, false, true, "The file could not be shared."),
			(
				"com.apple.UIKit.activity.CopyToPasteboard", true, false,
				"Shared. iOS handed the file to the app you chose."
			),
			(
				"com.apple.DocumentManagerUICore.SaveToFiles", false, false,
				"Canceled. The file was not shared."
			),
		]
		let model = await harness.model(try harness.services())
		let support = model.support
		let folder = harness.launch.directory.appending(path: "EnduragentDiagnostics")
		let observing = Task { await support.appear() }
		defer { observing.cancel() }
		try await until { support.snapshot != nil }
		for share in cases {
			await support.makeDiagnosticsFile()
			let handle = try #require(support.sharing)
			#expect(FileManager.default.fileExists(atPath: handle.url.path))
			#expect(!support.canMakeDiagnosticsFile)
			try await until { support.diagnosticsLine == nil }
			await support.shareFinished(
				activityType: share.activity, completed: share.completed,
				error: share.fails ? CocoaError(.fileWriteUnknown) : nil)
			try await until {
				support.diagnosticsLine.map { model.phrasebook.say($0) } == share.sentence
			}
			#expect(support.sharing == nil)
			#expect(support.canMakeDiagnosticsFile)
			#expect(try entries(in: folder).isEmpty)
		}
	}

	private func entries(in folder: URL) throws -> [URL] {
		do {
			return try FileManager.default.contentsOfDirectory(
				at: folder, includingPropertiesForKeys: nil)
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			return []
		}
	}
}
