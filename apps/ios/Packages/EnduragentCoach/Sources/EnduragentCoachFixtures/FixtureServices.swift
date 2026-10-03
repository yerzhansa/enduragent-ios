import EnduragentCoach

extension RecordStore {
	public static func inMemory(deviceId: DeviceID) -> RecordStore {
		RecordStore(log: InMemoryRecordLog(deviceId: deviceId))
	}
}

extension ModelService {
	public static func scripted(_ fake: FakeModelTransport) -> ModelService {
		ModelService { _ in fake }
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
	public func installOpenRouterChoice(model: ModelID, key: String) throws {
		try storeOpenRouterAccountKey(key, at: .legacy)
		try storeAccessSelection(
			.init(.openRouter(SavedOpenRouterReference(credential: .legacy, model: model))))
	}
}

extension TrainingService {
	public static func fake(
		_ client: @escaping @Sendable (IntervalsCredential, AthleteSelection) -> any IntervalsClient
	) -> TrainingService {
		TrainingService { credential, athlete, _ in client(credential, athlete) }
	}
}
