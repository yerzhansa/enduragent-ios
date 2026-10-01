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
	public static func fake(_ client: FakeCreditsClient) -> CreditsService {
		CreditsService { _ in client }
	}
}

extension TrainingService {
	public static func fake(
		_ client: @escaping @Sendable (IntervalsCredential, AthleteSelection) -> any IntervalsClient
	) -> TrainingService {
		TrainingService { credential, athlete, _ in client(credential, athlete) }
	}
}
