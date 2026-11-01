import EnduragentCoach
import Foundation

extension RecordStore {
	public static func inMemory(deviceId: DeviceID) -> RecordStore {
		RecordStore(log: InMemoryRecordLog(deviceId: deviceId))
	}
}

extension ModelService {
	public static func scripted(_ fake: FakeModelTransport, catalog: ModelCatalog = .fixture)
		-> ModelService
	{
		ModelService(catalog: catalog) { _ in fake }
	}

	public static func scripted(
		_ fake: FakeModelTransport, catalogSource: FakeModelCatalogSource,
		cacheDirectory: URL, catalog: ModelCatalog = .bundled
	) -> ModelService {
		ModelService(
			catalog: catalog, catalogSource: catalogSource,
			catalogCache: FileModelCatalogCache(directory: cacheDirectory)
		) { _ in fake }
	}
}

extension CreditsService {
	public static func fake(_ client: FakeCreditsClient, mintedKey: String? = nil) -> CreditsService
	{
		CreditsService { vault in
			client.provision(using: vault, mintedKey: mintedKey)
			return client
		}
	}
}

extension ICloudKeychainStore {
	public func installOpenRouterChoice(
		model: ModelID, key: String, catalog: ModelCatalog = .fixture
	) throws {
		let entry = try catalog.choice(model)
		try storeOpenRouterAccountKey(key, at: .legacy)
		try storeAccessSelection(
			.init(
				.openRouter(
					SavedOpenRouterReference(
						credential: .legacy, model: model, details: entry.details))))
	}
}

extension TrainingService {
	public static func fake(
		_ client: @escaping @Sendable (IntervalsCredential, AthleteSelection) -> FakeIntervalsClient
	) -> TrainingService {
		TrainingService { credential, athlete in client(credential, athlete) }
	}
}

extension AppIdentity {
	public static let fixture: AppIdentity = {
		guard let app = AppIdentity(name: "Enduragent", version: "0.1.0", build: "3") else {
			preconditionFailure("The fixture app identity does not fit its shapes")
		}
		return app
	}()
}

extension SupportService {
	public static func inMemory(app: AppIdentity, server: FakeFeedbackServer = FakeFeedbackServer())
		-> SupportService
	{
		SupportService(
			journal: MemoryJournalStorage(), keptNotes: MemoryKeptNoteStorage(watching: server),
			shareFolder: ShareFolder(
				in: FileManager.default.temporaryDirectory.appending(
					path: "enduragent-share-\(UUID().uuidString)", directoryHint: .isDirectory)),
			feedback: server.client, app: app, device: .fixture)
	}

	public static func fixture(
		directory: URL, app: AppIdentity, server: FakeFeedbackServer = FakeFeedbackServer(),
		journal: FixtureJournal = .saving
	) -> SupportService {
		let file = FileJournalStorage(directory: directory)
		let storage: any JournalStorage
		switch journal {
		case .saving: storage = file
		case .notSaving: storage = UnwritableJournalStorage(file: file)
		}
		return SupportService(
			journal: storage,
			keptNotes: FileKeptNoteStorage(directory: directory),
			shareFolder: ShareFolder(in: directory),
			feedback: server.client, app: app, device: .fixture)
	}
}

public enum FixtureJournal: String, Sendable {
	case saving
	case notSaving
}

private struct UnwritableJournalStorage: JournalStorage {
	let file: FileJournalStorage

	func read() throws -> Data? {
		try file.read()
	}

	func append(_ line: Data) throws {
		throw CocoaError(.fileWriteNoPermission)
	}

	func replace(with lines: Data) throws {
		throw CocoaError(.fileWriteNoPermission)
	}

	func erase() throws {
		try file.erase()
	}

	func removeLeftover() throws {
		throw CocoaError(.fileWriteNoPermission)
	}
}
