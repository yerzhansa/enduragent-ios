import Foundation

public struct CoachPorts: Sendable {
	public let records: any RecordLog
	public let secrets: any SecretStore
	public let models: ModelService
	public let training: TrainingService
	public let credits: CreditsService
	public let clock: any Clock

	public init(
		records: any RecordLog,
		secrets: any SecretStore,
		models: ModelService,
		training: TrainingService,
		credits: CreditsService,
		clock: any Clock
	) {
		self.records = records
		self.secrets = secrets
		self.models = models
		self.training = training
		self.credits = credits
		self.clock = clock
	}
}
