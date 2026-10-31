import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct ModelContainerHandleTests {
		@Test func twoOpensOfOneStoreDirectoryShareOneHandle() throws {
			let directory = try TestTemporaryFolders.make()
			let other = try TestTemporaryFolders.make()

			let first = try ModelContainerHandle.deviceLocal(directory: directory)
			let second = try ModelContainerHandle.deviceLocal(directory: directory)
			let respelled = try ModelContainerHandle.deviceLocal(
				directory: directory.appending(path: ".", directoryHint: .isDirectory))
			let elsewhere = try ModelContainerHandle.deviceLocal(directory: other)

			#expect(first === second)
			#expect(first === respelled)
			#expect(first !== elsewhere)
		}
	}
}
