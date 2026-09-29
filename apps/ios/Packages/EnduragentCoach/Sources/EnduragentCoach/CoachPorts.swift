import Foundation

public struct CoachPorts: Sendable {
	public let records: RecordStore
	public let secrets: any SecretStore
	public let models: ModelService
	public let training: TrainingService
	public let credits: CreditsService
	public let host: any ExecutionHost
	public let clock: any Clock

	public init(
		records: RecordStore,
		secrets: any SecretStore,
		models: ModelService,
		training: TrainingService,
		credits: CreditsService,
		host: any ExecutionHost,
		clock: any Clock
	) {
		self.records = records
		self.secrets = secrets
		self.models = models
		self.training = training
		self.credits = credits
		self.host = host
		self.clock = clock
	}
}

public struct RecordStore: Sendable {
	package let log: any RecordLog

	public static func onDevice(deviceId: DeviceID) throws -> RecordStore {
		let directory = try ModelContainerHandle.applicationSupportDirectory()
		return RecordStore(
			log: SwiftDataRecordLog(
				deviceId: deviceId,
				synced: try ModelContainerHandle.syncedCloudKit(directory: directory),
				local: try ModelContainerHandle.deviceLocal(directory: directory)))
	}

	public static func inMemory(deviceId: DeviceID) -> RecordStore {
		RecordStore(log: InMemoryRecordLog(deviceId: deviceId))
	}

	public static func fixture(
		directory: URL, deviceId: DeviceID, unreadable: Bool = false
	) throws -> (store: RecordStore, faults: RecordFaults) {
		if unreadable {
			try FileManager.default.createDirectory(
				at: directory.appending(path: ModelContainerHandle.syncedStoreFileName),
				withIntermediateDirectories: true)
		}
		let faults = try RecordFaults(directory: directory, deviceId: deviceId)
		return (RecordStore(log: faults.log), faults)
	}
}

public struct ModelService: Sendable {
	public static let openRouterAPI: URL = {
		guard let url = URL(string: "https://openrouter.ai/api/v1") else {
			fatalError("https://openrouter.ai/api/v1 is invalid")
		}
		return url
	}()

	package let makeTransport: @Sendable (DiagnosticsLog) -> any ModelTransport

	public static func openRouter(baseURL: URL) -> ModelService {
		ModelService { diagnostics in
			OpenRouterTransport(baseURL: baseURL, diagnostics: diagnostics)
		}
	}

	public static func scripted(_ fake: FakeModelTransport) -> ModelService {
		ModelService { _ in fake }
	}
}
