import Foundation

public struct CoachPorts: Sendable {
	public let records: any RecordLog
	public let secrets: any SecretStore
	public let models: ModelService
	public let training: TrainingService
	public let credits: CreditsService
	public let host: any ExecutionHost
	public let clock: any Clock

	public init(
		records: any RecordLog,
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
