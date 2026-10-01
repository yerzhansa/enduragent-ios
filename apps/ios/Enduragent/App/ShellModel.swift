import EnduragentCoach
import Foundation
import Observation

@MainActor
@Observable
final class ShellModel {
	var route: ShellRoute = .onboarding(.notice)
	private(set) var chat: ChatSnapshot?
	private(set) var languageNotSaved: LanguagePreference?
	var showLanguage = false
	var draft = Draft(id: DraftID(), text: "")
	var notSent = false
	private(set) var isSending = false
	private(set) var consentNotSaved = false
	private(set) var isRecordingConsent = false
	var slashListVisible = false
	private(set) var status: CoachStatus?
	var starterLine: String?
	var starterResolved = false
	var balance: Credits?
	var catalog: PackCatalog?
	var creditsNotice: AthleteNotice?
	private(set) var history: HistoryList = .loading
	private(set) var newConversationUncertain = false
	var connectKey = ""
	var connectError: String?
	var didConnect = false
	private(set) var reviewNotice: AthleteNotice?
	var showSidebar = false
	var showCredits = false
	var packPrices: [String: String] = [:]

	let environment: AppEnvironment
	let lifecycle: AppLifecycle
	let drafts: DraftStore
	private let defaults: UserDefaults
	private let initialLanguage: LanguagePreference
	private var starterLoaded = false
	private var observation: Task<Void, Never>?
	private var statusStart: Task<Void, Never>?
	private var statusObservation: Task<Void, Never>?

	init(environment: AppEnvironment, initialLanguage: LanguagePreference = .automatic) {
		self.initialLanguage = initialLanguage
		self.environment = environment
		self.lifecycle = AppLifecycle(environment: environment)
		self.defaults = environment.defaults
		self.drafts = DraftStore(defaults: environment.defaults)
		if defaults.bool(forKey: Self.onboardingCompletedKey) {
			route = .loading
		}
		draft = drafts.load(.main) ?? Draft(id: DraftID(), text: "")
	}

	deinit {
		observation?.cancel()
		statusStart?.cancel()
		statusObservation?.cancel()
	}

	static let onboardingCompletedKey = "enduragent.onboardingCompleted"

	var services: AppServices {
		environment.services
	}

	var languagePreference: LanguagePreference {
		status?.language ?? initialLanguage
	}

	var phrasebook: CatalogPhrasebook {
		languagePreference.phrasebook(device: environment.language)
	}

	var languageNotSavedLine: String? {
		languageNotSaved.map {
			$0.notSaved(keeping: languagePreference, in: phrasebook)
		}
	}

	var connected: IntervalsSummary? {
		guard case .connected(let summary, _)? = status?.training else { return nil }
		return summary
	}

	var athleteFirstName: String {
		guard let name = connected?.athleteName?.trimmingCharacters(in: .whitespacesAndNewlines),
			!name.isEmpty
		else {
			return ""
		}
		return name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
	}

	var isWorking: Bool {
		chat.map { $0.activity != .idle } ?? false
	}

	func continueNotice() {
		route = .onboarding(.connect)
	}

	func connect() async {
		let outcome = await services.coach.changeTraining(
			.replace(apiKey: connectKey, athlete: .keyOwner))
		switch outcome {
		case .replaced:
			connectKey = ""
			connectError = nil
			didConnect = true
		case .kept, .disconnected, .refused, .failedPreviousKept:
			connectError = phrasebook.say(Catalog.connectErrorRejected, [:])
			didConnect = false
		}
	}

	func continueConnect() {
		guard didConnect else { return }
		connectKey = ""
		route = .onboarding(.starter)
	}

	func skipConnect() {
		connectKey = ""
		didConnect = false
		connectError = nil
		route = .onboarding(.starter)
	}

	func loadStarter() async {
		guard !starterLoaded else { return }
		starterLoaded = true
		do {
			let token = try await environment.deviceCheck.token()
			let outcome = try await services.coach.credits.grant(deviceCheck: token)
			switch outcome {
			case .minted(let credits):
				starterLine = phrasebook.say(
					Catalog.creditsBalance, count: credits.units,
					["formattedCount": String(credits.units)])
			case .toppedUp(let added):
				starterLine = phrasebook.say(
					Catalog.onboardingStarterAdded, count: added.units,
					["formattedCount": String(added.units)])
			case .alreadyGranted:
				starterLine =
					try await existingBalanceLine()
					?? phrasebook.say(Catalog.onboardingStarterAlreadyGranted, [:])
			}
		} catch {
			starterLine = AthleteNotice.credits(failure: error).sentence(in: phrasebook)
		}
		starterResolved = true
	}

	private func existingBalanceLine() async throws -> String? {
		guard try await services.coach.creditsIdentity().hasCreditsKey else { return nil }
		let scale = try await services.coach.credits.catalog().scale
		let balance = try await services.coach.credits.balance(scale: scale)
		return phrasebook.say(
			Catalog.creditsBalance, count: balance.credits.units,
			["formattedCount": String(balance.credits.units)])
	}

	func appear() async {
		let coach = services.coach
		let starting =
			statusStart
			?? Task { [weak self] in
				var snapshots = await coach.observeStatus().makeAsyncIterator()
				guard let first = await snapshots.next(), let self, !Task.isCancelled else {
					return
				}
				self.receiveStatus(first)
				self.statusObservation = Task { [weak self] in
					while let snapshot = await snapshots.next() {
						guard let self, !Task.isCancelled else { return }
						self.receiveStatus(snapshot)
					}
				}
			}
		statusStart = starting
		await starting.value
	}

	private func receiveStatus(_ current: CoachStatus) {
		status = current
		updateRoute()
	}

	private func updateRoute() {
		guard let status else { return }
		switch route {
		case .loading, .chat, .onboarding(.consent), .onboarding(.consentDeferred):
			if status.needsProviderConsent {
				if route == .loading || route == .chat { route = .onboarding(.consent) }
			} else {
				route = .chat
				observeChat()
			}
		case .onboarding(.notice), .onboarding(.connect), .onboarding(.starter):
			break
		}
	}

	func sceneChanged(_ event: AppLifecycleEvent) async {
		await lifecycle.forward(event)
	}

	func startChatting() async {
		defaults.set(true, forKey: Self.onboardingCompletedKey)
		route = .loading
		await appear()
		updateRoute()
	}

	func acceptConsent() async {
		guard
			route == .onboarding(.consent) || route == .onboarding(.consentDeferred),
			!isRecordingConsent
		else { return }
		isRecordingConsent = true
		defer { isRecordingConsent = false }
		consentNotSaved = false
		do {
			try await services.coach.recordConsent()
		} catch {
			switch error {
			case .notSaved:
				consentNotSaved = true
			}
			return
		}
		await startChatting()
	}

	func declineConsent() {
		guard route == .onboarding(.consent), !isRecordingConsent else { return }
		consentNotSaved = false
		route = .onboarding(.consentDeferred)
	}

	func newConversation() async {
		reviewNotice = nil
		showNewConversation(await services.coach.startNewConversation(in: .main))
	}

	func loadHistory() async {
		do {
			history = .loaded(try await services.coach.history())
		} catch {
			switch error {
			case .storageUnavailable:
				history = .unavailable
			}
		}
	}

	func loadCredits() async {
		do {
			let loaded = try await services.coach.credits.catalog()
			catalog = loaded
			let held = try await services.coach.credits.balance(scale: loaded.scale)
			balance = held.credits
			creditsNotice = nil
			packPrices = try await services.packPrices(loaded.packs.map(\.id))
		} catch {
			creditsNotice = AthleteNotice.credits(failure: error)
		}
	}

	func draftChanged(from previous: String) {
		if previous.isEmpty, !draft.text.isEmpty {
			draft = Draft(id: DraftID(), text: draft.text)
		}
		drafts.save(draft, for: .main)
		updateSlashList()
	}

	func updateSlashList() {
		slashListVisible = draft.text.hasPrefix("/") && !draft.text.contains(where: \.isWhitespace)
	}

	func fillSlash(_ command: SlashCommand) {
		draft.text = command.rawValue + " "
		drafts.save(draft, for: .main)
		updateSlashList()
	}

	func send() async {
		let sent = draft
		let text = sent.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, !isSending else { return }
		isSending = true
		defer { isSending = false }
		notSent = false
		newConversationUncertain = false
		reviewNotice = nil
		slashListVisible = false
		do {
			switch try await services.coach.send(Draft(id: sent.id, text: text), to: .main) {
			case .accepted:
				clear(sent)
			case .showLanguagePicker:
				clear(sent)
				languageNotSaved = nil
				showLanguage = true
			case .newConversation(let outcome):
				clear(sent)
				showNewConversation(outcome)
			case .ignoredBlank:
				break
			}
		} catch {
			switch error {
			case .storageUnavailable:
				notSent = true
			}
		}
	}

	private func clear(_ sent: Draft) {
		guard draft.id == sent.id else { return }
		draft = Draft(id: DraftID(), text: draft == sent ? "" : draft.text)
		drafts.save(draft, for: .main)
	}

	func stop() async {
		await services.coach.stop(.main)
	}

	func chooseLanguage(_ preference: LanguagePreference) async {
		do {
			try await services.coach.setLanguage(preference)
			languageNotSaved = nil
		} catch {
			switch error {
			case .notSaved:
				languageNotSaved = preference
			}
		}
	}

	func saveSession(_ settings: SessionSettings) async throws(PreferenceWriteFailure) {
		try await services.coach.setSession(settings)
	}

	func decide(_ decision: ReviewDecision) async {
		let outcome = await services.coach.decide(decision, in: .main)
		switch decision {
		case .approve, .cancel, .retryRemaining, .checkAgain:
			reviewNotice = outcome.notice
		case .presented, .presentationFailed, .showAgain:
			break
		}
	}

	private func showNewConversation(_ outcome: ResetOutcome) {
		switch outcome {
		case .started:
			newConversationUncertain = false
		case .notStarted:
			newConversationUncertain = true
		}
	}

	private func observeChat() {
		guard observation == nil else { return }
		let coach = services.coach
		observation = Task { [weak self] in
			for await snapshot in await coach.observe(.main) {
				guard let self, !Task.isCancelled else { return }
				self.chat = snapshot
			}
		}
	}
}
