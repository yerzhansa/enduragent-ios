import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

struct FixtureTestScope: SuiteTrait, TestTrait, TestScoping {
	@TaskLocal static var current: AppTestFixture?
	let isRecursive = true

	func provideScope(
		for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
	) async throws {
		guard !test.isSuite else {
			try await function()
			return
		}
		let fixture = try await AppTestFixture()
		try await FixtureFolder.$current.withValue(fixture.folder) {
			try await FixtureTestScope.$current.withValue(fixture) {
				do {
					try await function()
				} catch {
					Issue.record(error)
				}
				try await fixture.cleanup()
			}
		}
	}
}

@MainActor
final class AppTestFixture {
	static var active: AppTestFixture {
		guard let current = FixtureTestScope.current else {
			preconditionFailure("The app test needs FixtureTestScope")
		}
		return current
	}

	let launch: FixtureLaunch
	let defaults: UserDefaults
	let folder: FixtureFolder
	private var models: [ShellModel] = []
	private var coaches: [Coach] = []
	private var memoryRecords: RecordStore?

	init() throws {
		let id = UUID().uuidString
		launch = FixtureLaunch(
			name: FixtureLaunch.firstWeekName, store: .fresh, keychain: .unlocked,
			directory: try TestTemporaryFolders.make(),
			defaultsSuiteName: "enduragent.app.test.\(id)")
		defaults = try launch.prepare()
		folder = try FixtureFolder(directory: launch.directory)
	}

	var records: RecordStore {
		if let memoryRecords { return memoryRecords }
		let records = RecordStore.inMemory(deviceId: DeviceID())
		memoryRecords = records
		return records
	}

	func own(_ services: AppServices) -> AppServices {
		coaches.append(services.coach)
		return services
	}

	func own(_ model: ShellModel) -> ShellModel {
		models.append(model)
		coaches.append(model.services.coach)
		return model
	}

	func releaseOwners() async {
		for model in models { await model.lifecycle.forward(.willTerminate) }
		for coach in coaches { await coach.lifecycle(.willTerminate) }
		models.removeAll()
		coaches.removeAll()
		memoryRecords = nil
	}

	func cleanup() async throws {
		defer { defaults.removePersistentDomain(forName: launch.defaultsSuiteName) }
		try await folder.cleanup { await self.releaseOwners() }
	}
}

@MainActor
func fixtureServices(_ launch: FixtureLaunch, defaults: UserDefaults) throws -> AppServices {
	AppTestFixture.active.own(
		try AppServices.fixture(
			launch, defaults: defaults, backgroundSystem: StubBackgroundSystem()))
}

@MainActor
func fixtureModel(
	environment: AppEnvironment, initialLanguage: LanguagePreference = .automatic
) -> ShellModel {
	AppTestFixture.active.own(
		ShellModel(environment: environment, initialLanguage: initialLanguage))
}

@MainActor
struct FixtureScopeTests {
	@Test(FixtureTestScope())
	func recursiveScopeProvidesATestFixture() {
		#expect(FileManager.default.fileExists(atPath: AppTestFixture.active.launch.directory.path))
	}

	@Test(.timeLimit(.minutes(1)))
	func cleanupWaitsForTheAppModelCoachAndRecordStore() async throws {
		let fixture = try AppTestFixture()
		let held = AsyncStream<Void>.makeStream()
		let opened = AsyncStream<Void>.makeStream()
		try await FixtureFolder.$current.withValue(fixture.folder) {
			try await FixtureTestScope.$current.withValue(fixture) {
				try await withThrowingTaskGroup(of: Bool.self) { group in
					defer {
						held.continuation.finish()
						opened.continuation.finish()
						group.cancelAll()
					}
					group.addTask {
						try await holdOwners(
							of: fixture, opened: opened.continuation, until: held.stream)
						return true
					}
					group.addTask {
						for await _ in opened.stream {}
						try Task.checkCancellation()
						try await checkCleanup(of: fixture, releasing: held.continuation)
						return true
					}
					group.addTask {
						try await Task.sleep(for: TestWaitLimit.hangGuard.duration)
						return false
					}
					for _ in 0..<2 {
						try #require(
							try await group.next() == true,
							"The app fixture ownership proof did not finish before the test hang guard expired"
						)
					}
				}
			}
		}
	}

	private func holdOwners(
		of fixture: AppTestFixture, opened: AsyncStream<Void>.Continuation,
		until held: AsyncStream<Void>
	) async throws {
		let records = try FixtureRecordStore(
			directory: fixture.launch.directory, deviceId: DeviceID())
		let services = try fixtureServices(fixture.launch, defaults: fixture.defaults)
		let model = fixtureModel(
			environment: AppEnvironment(
				services: services, language: .en, defaults: fixture.defaults))
		await model.appear()
		opened.finish()
		for await _ in held {}
		withExtendedLifetime((model, services.coach, records)) {}
	}

	private func checkCleanup(
		of fixture: AppTestFixture, releasing held: AsyncStream<Void>.Continuation
	) async throws {
		let cleanup = Task { try await fixture.cleanup() }
		defer { cleanup.cancel() }
		var waiting = fixture.folder.waitingForStores.makeAsyncIterator()
		try #require(await waiting.next() != nil)
		#expect(FileManager.default.fileExists(atPath: fixture.launch.directory.path))
		held.finish()
		try await cleanup.value
		#expect(!FileManager.default.fileExists(atPath: fixture.launch.directory.path))
	}
}
