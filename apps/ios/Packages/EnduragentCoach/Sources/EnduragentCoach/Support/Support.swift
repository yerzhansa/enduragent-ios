import Foundation

public actor Support {
	package nonisolated let log: DiagnosticsLog
	public nonisolated let about: About
	private let service: SupportService
	private let census: SupportCensus
	private let feed = SnapshotFeed<SupportSnapshot>()
	private let healthChanges: AsyncStream<JournalHealth>
	private var following: Task<Void, Never>?
	private var file: DiagnosticsFileState = .idle

	deinit {
		following?.cancel()
	}

	init(log: DiagnosticsLog, service: SupportService, census: SupportCensus) {
		self.log = log
		about = About(app: service.app)
		self.service = service
		self.census = census
		healthChanges = log.healthChanges()
		do {
			try service.shareFolder.sweep()
		} catch {
			log.record(.diagnosticsFileFailed(.couldNotWrite, FailureCode(error)))
		}
	}

	public func observe() -> AsyncStream<SupportSnapshot> {
		if following == nil {
			let changes = healthChanges
			following = Task { [weak self] in
				for await _ in changes {
					guard let self else { return }
					await self.publish()
				}
			}
		}
		return feed.subscribe(from: snapshot)
	}

	public func makeDiagnosticsFile() async -> DiagnosticsFileState {
		if case .preparing = file { return file }
		if case .ready(let earlier) = file { remove(earlier) }
		show(.preparing)
		let facts = await census.status()
		let records = await census.records()
		let made = log.clock.now
		let contents = DiagnosticsFile(
			made: made, app: about.app, device: service.device, facts: facts, records: records,
			journal: log.health, lines: log.window(endingAt: made))
		do {
			show(
				.ready(
					try service.shareFolder.write(
						try contents.encoded(), named: contents.name(in: log.clock.timeZone),
						id: ULID.generate(at: made))))
		} catch {
			log.record(.diagnosticsFileFailed(.couldNotWrite, FailureCode(error)))
			show(.failed(.couldNotWrite))
		}
		return file
	}

	public func finishShare(_ handle: DiagnosticsFileHandle, _ outcome: ShareOutcome)
		-> DiagnosticsFileState
	{
		guard case .ready(handle) = file else { return file }
		remove(handle)
		show(outcome.state)
		return file
	}

	private func remove(_ handle: DiagnosticsFileHandle) {
		do {
			try service.shareFolder.remove(handle)
		} catch {
			log.record(.diagnosticsFileFailed(.couldNotWrite, FailureCode(error)))
		}
	}

	private func show(_ state: DiagnosticsFileState) {
		file = state
		publish()
	}

	private func publish() {
		feed.publish(snapshot)
	}

	private var snapshot: SupportSnapshot {
		SupportSnapshot(diagnosticsFile: file, journal: log.health)
	}
}

public struct SupportSnapshot: Sendable, Equatable {
	public let diagnosticsFile: DiagnosticsFileState
	public let journal: JournalHealth
}

public struct About: Sendable, Equatable {
	public static let privacyPolicy: URL = {
		guard let url = URL(string: "https://enduragent.icu/privacy.html") else {
			fatalError("The privacy policy URL is invalid")
		}
		return url
	}()

	public let app: AppIdentity
}

extension SupportCensus {
	init(ledger: Ledger, preferences: CoachPreferences, vault: CredentialVault) {
		self.init(
			status: {
				StatusFacts(
					access: AccessKind(await preferences.accessStatus()),
					training: ConnectionKind(await vault.storedTrainingStatus()),
					language: LanguageCode(await preferences.load().language))
			},
			records: { await ledger.census() })
	}
}
