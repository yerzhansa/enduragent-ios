import Foundation

public struct SupportService: Sendable {
	package let journal: any JournalStorage
	package let app: AppIdentity
	package let device: DeviceFacts

	package init(journal: any JournalStorage, app: AppIdentity, device: DeviceFacts) {
		self.journal = journal
		self.app = app
		self.device = device
	}

	public static func onDevice(app: AppIdentity) throws -> SupportService {
		SupportService(
			journal: FileJournalStorage(
				directory: try ModelContainerHandle.applicationSupportDirectory()),
			app: app, device: .current())
	}

	package func openLog(clock: any Clock) -> DiagnosticsLog {
		DiagnosticsLog(clock: clock, storage: journal)
	}
}
