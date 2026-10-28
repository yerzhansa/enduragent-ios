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
	public static func inMemory(app: AppIdentity) -> SupportService {
		SupportService(journal: MemoryJournalStorage(), app: app, device: .fixture)
	}

	public static func fixture(directory: URL, app: AppIdentity) -> SupportService {
		SupportService(
			journal: FileJournalStorage(directory: directory), app: app, device: .fixture)
	}
}
