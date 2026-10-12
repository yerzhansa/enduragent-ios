import BackgroundTasks
import EnduragentCoach
import UIKit
import UserNotifications

@MainActor
protocol ContinuedTask: AnyObject {
	var progress: Progress { get }
	var expirationHandler: (() -> Void)? { get set }
	func setTaskCompleted(success: Bool)
	func updateTitle(_ title: String, subtitle: String)
}

extension BGContinuedProcessingTask: ContinuedTask {}

@MainActor
protocol BackgroundSystem: AnyObject {
	var isActive: Bool { get }
	func register(_ identifier: String, launchHandler: @escaping (any ContinuedTask) -> Void)
		-> Bool
	func submit(_ request: BGContinuedProcessingTaskRequest) throws
	func cancel(_ identifier: String)
	func beginGrace(named name: String, expiration: @escaping () -> Void)
		-> UIBackgroundTaskIdentifier
	func endGrace(_ identifier: UIBackgroundTaskIdentifier)
	func allowQuietNotifications() async throws
	func post(_ request: UNNotificationRequest) async throws
}

enum ContinuedProcessingRefusal: Error, Equatable {
	case handlerNotRegistered(String)
}

@MainActor
final class ContinuedProcessingHost: ExecutionHost {
	static let keptLeases = 50

	private let bundleIdentifier: String
	let system: any BackgroundSystem
	private(set) var leases: [LeaseRecord] = []

	init(bundleIdentifier: String, system: any BackgroundSystem) {
		self.bundleIdentifier = bundleIdentifier
		self.system = system
	}

	func beginLease(
		_ request: LeaseRequest, onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) async -> any ExecutionLease {
		let identifier = "\(bundleIdentifier).coach.\(ULID.generate(at: Date()).rawValue)"
		var refusal: String?
		if request.initiatedBy == .athlete {
			allowNotifications(for: identifier)
			let lease = ContinuedProcessingLease(
				identifier, kind: .continuedProcessing, request: request, host: self,
				onExpiry: onExpiry)
			do {
				try submit(request, identifier: identifier, to: lease)
				keep(LeaseRecord(id: identifier, request: request, kind: lease.kind))
				return lease
			} catch {
				refusal = String(describing: error)
			}
		}
		let lease = ContinuedProcessingLease(
			identifier, kind: .gracePeriodOnly, request: request, host: self, onExpiry: onExpiry)
		var record = LeaseRecord(id: identifier, request: request, kind: lease.kind)
		record.notes += [refusal].compactMap { $0 }
		keep(record)
		lease.beginGrace()
		return lease
	}

	func update(_ identifier: String, _ change: (inout LeaseRecord) -> Void) {
		guard let index = leases.firstIndex(where: { $0.id == identifier }) else { return }
		change(&leases[index])
	}

	func notify(_ notice: CompletionNotice, lease identifier: String) async {
		guard !system.isActive else { return }
		let content = UNMutableNotificationContent()
		content.title = notice.titleText
		content.body = notice.excerpt
		let request = UNNotificationRequest(
			identifier: "\(bundleIdentifier).reply.\(notice.turn.ulid.rawValue)",
			content: content, trigger: nil)
		do {
			try await system.post(request)
		} catch {
			update(identifier) { $0.notes.append(String(describing: error)) }
		}
	}

	private func keep(_ record: LeaseRecord) {
		leases.append(record)
		leases.removeFirst(max(0, leases.count - Self.keptLeases))
	}

	private func submit(
		_ request: LeaseRequest, identifier: String, to lease: ContinuedProcessingLease
	) throws {
		guard system.register(identifier, launchHandler: { task in lease.attach(task) }) else {
			throw ContinuedProcessingRefusal.handlerNotRegistered(identifier)
		}
		let task = BGContinuedProcessingTaskRequest(
			identifier: identifier, title: request.titleText, subtitle: "")
		task.strategy = .fail
		try system.submit(task)
	}

	private func allowNotifications(for identifier: String) {
		Task {
			do {
				try await system.allowQuietNotifications()
			} catch {
				update(identifier) { $0.notes.append(String(describing: error)) }
			}
		}
	}
}

@MainActor
final class ContinuedProcessingLease: ExecutionLease {
	nonisolated let kind: LeaseKind
	private let identifier: String
	private let host: ContinuedProcessingHost
	private let onExpiry: @Sendable (ExpiryCause) async -> Void
	private var attachment = Attachment.awaitingLaunch
	private var title: String
	private var state = State.active
	private var grace = UIBackgroundTaskIdentifier.invalid
	private var progress: LeaseProgress?
	private enum Attachment {
		case awaitingLaunch
		case continued(any ContinuedTask)
		case completed
	}

	private enum State {
		case active
		case settling
		case ended(LeaseEnding)
	}

	init(
		_ identifier: String, kind: LeaseKind, request: LeaseRequest, host: ContinuedProcessingHost,
		onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) {
		self.identifier = identifier
		self.kind = kind
		self.host = host
		self.title = request.titleText
		self.onExpiry = onExpiry
	}

	func attach(_ task: any ContinuedTask) {
		guard case .awaitingLaunch = attachment else { return }
		attachment = .continued(task)
		if case .ended(let ending) = state {
			complete(ending)
			return
		}
		task.updateTitle(title, subtitle: "")
		task.expirationHandler = { Task { await self.expire(.systemExpired) } }
		if let progress {
			mirror(progress, on: task)
		}
	}

	func beginGrace() {
		grace = host.system.beginGrace(named: identifier) {
			Task { await self.expire(.graceEnded) }
		}
	}

	func report(_ progress: LeaseProgress) async {
		self.progress = progress
		host.update(identifier) { $0.progress = progress }
		if case .continued(let task) = attachment {
			mirror(progress, on: task)
		}
	}

	func updateTitle(_ title: CatalogKey, language: LanguageTag) async {
		guard case .active = state else { return }
		self.title = language.phrasebook.say(title)

		if case .continued(let task) = attachment {
			task.updateTitle(self.title, subtitle: "")
		}
	}

	func end(_ ending: LeaseEnding) async {
		if case .settling = state, case .interrupted = ending {
			await close(ending)
		} else if case .active = state {
			await close(ending)
		}
	}

	private func expire(_ cause: ExpiryCause) async {
		guard case .active = state else { return }
		state = .settling
		host.update(identifier) { $0.expiry = cause }
		await onExpiry(cause)
		await close(.interrupted(cause == .systemExpired ? .systemExpired : .graceEnded))
	}

	private func close(_ ending: LeaseEnding) async {
		if case .ended = state { return }
		state = .ended(ending)
		host.update(identifier) { $0.ending = ending }
		complete(ending)
		switch ending {
		case .finished(let notice), .failed(let notice):
			if let notice {
				await host.notify(notice, lease: identifier)
			}
		case .interrupted:
			break
		}
	}

	private func complete(_ ending: LeaseEnding) {
		let success: Bool
		switch ending {
		case .finished, .failed, .interrupted(.athleteStopped):
			success = true
		case .interrupted:
			success = false
		}
		if case .awaitingLaunch = attachment, kind == .continuedProcessing {
			host.system.cancel(identifier)
		}
		if case .continued(let task) = attachment {
			attachment = .completed
			task.expirationHandler = nil
			task.setTaskCompleted(success: success)
		}
		if grace != .invalid {
			host.system.endGrace(grace)
			grace = .invalid
		}
	}

	private func mirror(_ progress: LeaseProgress, on task: any ContinuedTask) {
		let running = progress.settledTurns < progress.totalTurns ? progress.step : 0
		task.progress.totalUnitCount = Int64(progress.totalTurns * progress.stepLimit)
		task.progress.completedUnitCount = Int64(
			progress.settledTurns * progress.stepLimit + min(running, progress.stepLimit))
	}
}

@MainActor
final class LiveBackgroundSystem: BackgroundSystem {
	var isActive: Bool {
		UIApplication.shared.applicationState == .active
	}

	func register(_ identifier: String, launchHandler: @escaping (any ContinuedTask) -> Void)
		-> Bool
	{
		BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
			MainActor.assumeIsolated {
				guard let continued = task as? BGContinuedProcessingTask else {
					task.setTaskCompleted(success: false)
					return
				}
				launchHandler(continued)
			}
		}
	}

	func submit(_ request: BGContinuedProcessingTaskRequest) throws {
		try BGTaskScheduler.shared.submit(request)
	}

	func cancel(_ identifier: String) {
		BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
	}

	func beginGrace(named name: String, expiration: @escaping () -> Void)
		-> UIBackgroundTaskIdentifier
	{
		UIApplication.shared.beginBackgroundTask(withName: name) {
			MainActor.assumeIsolated { expiration() }
		}
	}

	func endGrace(_ identifier: UIBackgroundTaskIdentifier) {
		UIApplication.shared.endBackgroundTask(identifier)
	}

	func allowQuietNotifications() async throws {
		let center = UNUserNotificationCenter.current()
		guard await center.notificationSettings().authorizationStatus == .notDetermined else {
			return
		}
		guard try await center.requestAuthorization(options: [.alert, .sound, .provisional])
		else {
			throw NotificationsRefused.provisional
		}
	}

	func post(_ request: UNNotificationRequest) async throws {
		try await UNUserNotificationCenter.current().add(request)
	}
}

enum NotificationsRefused: Error, Equatable {
	case provisional
}
