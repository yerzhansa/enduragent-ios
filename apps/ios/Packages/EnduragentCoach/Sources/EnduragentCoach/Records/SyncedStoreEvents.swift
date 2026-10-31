import CloudKit
import CoreData
import Foundation

extension SwiftDataRecordLog {
	package static let exportWindow: Duration = .seconds(60)

	package func confirmSyncedExport(after saved: Date) async throws -> Bool {
		guard let identifier = synced.cloudKitContainer else { return true }
		guard try await CKContainer(identifier: identifier).accountStatus() == .available else {
			return false
		}
		let exports = syncedEvents(of: .export) { event in
			event.succeeded && event.startDate >= saved
		}
		let window = Self.exportWindow
		return await withTaskGroup(of: Bool.self) { group in
			group.addTask {
				for await _ in exports { return true }
				return false
			}
			group.addTask {
				do {
					try await Task.sleep(for: window)
				} catch is CancellationError {
					return false
				} catch {
					preconditionFailure("Task.sleep failed: \(error)")
				}
				return false
			}
			let first = await group.next() ?? false
			group.cancelAll()
			return first
		}
	}

	package var imports: AsyncStream<Void> {
		syncedEvents(of: .import) { _ in true }
	}

	private func syncedEvents(
		of type: NSPersistentCloudKitContainer.EventType,
		where admits: @escaping @Sendable (NSPersistentCloudKitContainer.Event) -> Bool
	) -> AsyncStream<Void> {
		AsyncStream { continuation in
			let urls = Set(synced.container.configurations.map(\.url))
			let changes = NotificationCenter.default.notifications(
				named: NSPersistentCloudKitContainer.eventChangedNotification)
			let task = Task {
				for await notification in changes {
					guard
						let event = notification.userInfo?[
							NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
							as? NSPersistentCloudKitContainer.Event,
						event.type == type, event.endDate != nil, admits(event),
						let container = notification.object as? NSPersistentCloudKitContainer,
						container.persistentStoreCoordinator.persistentStores.contains(where: {
							$0.identifier == event.storeIdentifier
								&& $0.url.map(urls.contains) == true
						})
					else { continue }
					continuation.yield()
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in
				task.cancel()
			}
		}
	}
}
