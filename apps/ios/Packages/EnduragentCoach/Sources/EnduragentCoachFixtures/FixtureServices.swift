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
		_ client: @escaping @Sendable (IntervalsCredential, AthleteSelection) -> any IntervalsClient
	) -> TrainingService {
		TrainingService { credential, athlete, _ in client(credential, athlete) }
	}
}
