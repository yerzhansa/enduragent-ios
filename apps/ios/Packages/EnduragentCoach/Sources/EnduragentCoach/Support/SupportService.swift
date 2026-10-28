import Foundation

public struct SupportService: Sendable {
	package let journal: any JournalStorage
	package let shareFolder: ShareFolder
	package let app: AppIdentity
	package let device: DeviceFacts

	package init(
		journal: any JournalStorage, shareFolder: ShareFolder, app: AppIdentity, device: DeviceFacts
	) {
		self.journal = journal
		self.shareFolder = shareFolder
		self.app = app
		self.device = device
	}

	public static func onDevice(app: AppIdentity) throws -> SupportService {
		SupportService(
			journal: FileJournalStorage(
				directory: try ModelContainerHandle.applicationSupportDirectory()),
			shareFolder: ShareFolder(in: FileManager.default.temporaryDirectory),
			app: app, device: .current())
	}

	package func openLog(clock: any Clock) -> DiagnosticsLog {
		DiagnosticsLog(clock: clock, storage: journal)
	}
}
