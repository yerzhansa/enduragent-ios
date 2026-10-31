import Foundation

public struct SupportService: Sendable {
	package let journal: any JournalStorage
	package let keptNotes: any KeptNoteStorage
	package let shareFolder: ShareFolder
	package let feedback: FeedbackClient
	package let app: AppIdentity
	package let device: DeviceFacts

	package init(
		journal: any JournalStorage, keptNotes: any KeptNoteStorage, shareFolder: ShareFolder,
		feedback: FeedbackClient, app: AppIdentity, device: DeviceFacts
	) {
		self.journal = journal
		self.keptNotes = keptNotes
		self.shareFolder = shareFolder
		self.feedback = feedback
		self.app = app
		self.device = device
	}

	public static func onDevice(app: AppIdentity) throws -> SupportService {
		let directory = try ModelContainerHandle.applicationSupportDirectory()
		return SupportService(
			journal: FileJournalStorage(directory: directory),
			keptNotes: FileKeptNoteStorage(directory: directory),
			shareFolder: ShareFolder(in: FileManager.default.temporaryDirectory),
			feedback: FeedbackClient.live, app: app, device: .current())
	}

	package func eraseFiles() throws {
		try journal.erase()
		try keptNotes.clear()
		try shareFolder.sweep()
	}

	package func openLog(clock: any Clock) -> DiagnosticsLog {
		DiagnosticsLog(clock: clock, storage: journal)
	}
}
