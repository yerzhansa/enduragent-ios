import EnduragentCoach
import Foundation
import Observation

@MainActor
@Observable
final class ShellModel {
	var route: ShellRoute = .onboarding(.notice) {
		didSet {
			if route != .chat { navigation.removeAll() }
		}
	}
	var navigation: [ShellDestination] = []
	private(set) var chat: ChatSnapshot?
	private(set) var languageNotSaved: LanguagePreference?
	var showLanguage = false
	var draft: Draft {
		get { submission.draft }
		set { submission.draft = newValue }
	}
	var notSent: Bool { submission.notSent }
	var isSending: Bool { submission.isSending }
	var slashListVisible: Bool {
		get { submission.slashListVisible }
		set { submission.slashListVisible = newValue }
	}
	private(set) var status: CoachStatus?
	var newConversationUncertain: Bool { submission.isUncertain(chat?.reset) }
	private var reviewOutcomeNotice: AthleteNotice?

	let environment: AppEnvironment
	let lifecycle: AppLifecycle
	let trainingSettings: TrainingSettingsModel
	private let submission: ChatSubmission
	var drafts: DraftStore { submission.drafts }
	private let onboarding: OnboardingModel
	private let credits: CreditsModel
	private let archive: HistoryModel
	private let initialLanguage: LanguagePreference
	private var observation: Task<Void, Never>?
	private var statusStart: Task<Void, Never>?
	private var statusObservation: Task<Void, Never>?

	init(environment: AppEnvironment, initialLanguage: LanguagePreference = .automatic) {
		self.initialLanguage = initialLanguage
		self.environment = environment
		self.lifecycle = AppLifecycle(environment: environment)
		self.trainingSettings = TrainingSettingsModel(coach: environment.services.coach)
		self.onboarding = OnboardingModel(environment: environment)
		self.credits = CreditsModel(services: environment.services)
		self.archive = HistoryModel(coach: environment.services.coach)
		self.submission = ChatSubmission(defaults: environment.defaults)
		if onboarding.isCompleted {
			route = .loading
		}
	}

	isolated deinit {
		observation?.cancel()
		statusStart?.cancel()
		statusObservation?.cancel()
	}

	static let onboardingCompletedKey = OnboardingModel.completedKey

	var connectKey: String {
		get { trainingSettings.key }
		set {
			if trainingSettings.state == .viewing { trainingSettings.edit() }
			trainingSettings.key = newValue
		}
	}

	var didConnect: Bool {
		if connected != nil { return true }
		if case .replaced? = trainingSettings.receipt { return true }
		return false
	}
	var starterLine: String? { onboarding.starterLine }
	var starterResolved: Bool { onboarding.starterResolved }
	var consentNotSaved: Bool { onboarding.consentNotSaved }
	var isRecordingConsent: Bool { onboarding.isRecordingConsent }
	var balance: Credits? { credits.balance }
	var catalog: PackCatalog? { credits.catalog }
	var creditsNotice: AthleteNotice? { credits.notice }
	var packPrices: [String: String] { credits.packPrices }
	var history: HistoryList { archive.list }

	var services: AppServices {
		environment.services
	}

	var languagePreference: LanguagePreference {
		status?.language ?? initialLanguage
	}

	var phrasebook: CatalogPhrasebook {
		languagePreference.phrasebook(device: environment.language)
	}

	var reviewNotice: AthleteNotice? {
		guard let reviewOutcomeNotice else { return nil }
		if let cardNotice = chat?.review?.notice,
			cardNotice.kind == .storageUnavailable
				|| (cardNotice.key == reviewOutcomeNotice.key
					&& cardNotice.vars == reviewOutcomeNotice.vars)
		{
			return nil
		}
		return reviewOutcomeNotice
	}

	var languageNotSavedLine: String? {
		languageNotSaved.map { _ in phrasebook.say(Catalog.reviewSaveFailed) }
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

	func open(_ destination: ShellDestination) {
		guard route == .chat else { return }
		navigation.append(destination)
	}

	func continueNotice() {
		trainingSettings.edit()
		route = .onboarding(.connect)
	}

	func connect() async {
		await trainingSettings.replace()
	}

	func continueConnect() {
		guard didConnect, !trainingSettings.isSaving else { return }
		trainingSettings.dismiss()
		route = .onboarding(.starter)
	}

	func skipConnect() {
		guard !trainingSettings.isSaving else { return }
		trainingSettings.dismiss()
		route = .onboarding(.starter)
	}

	func loadStarter() async {
		await onboarding.loadStarter { phrasebook }
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
					while let snapshot = await snapshots.next(isolation: MainActor.shared) {
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
		onboarding.complete()
		route = .loading
		await appear()
		updateRoute()
	}

	func acceptConsent() async {
		guard route == .onboarding(.consent) || route == .onboarding(.consentDeferred) else {
			return
		}
		await onboarding.acceptConsent { await startChatting() }
	}

	func declineConsent() {
		guard route == .onboarding(.consent), !isRecordingConsent else { return }
		onboarding.declineConsent()
		route = .onboarding(.consentDeferred)
	}

	func newConversation() async {
		reviewOutcomeNotice = nil
		await submission.newConversation(using: services.coach)
	}

	func loadHistory() async {
		await archive.load()
	}

	func loadArchivedConversation(_ ref: ArchivedConversationRef) async
		-> ArchivedConversationContent
	{
		await archive.loadArchivedConversation(ref)
	}

	func loadCredits() async {
		await credits.load()
	}

	func draftChanged(from previous: String) { submission.draftChanged(from: previous) }

	func fillSlash(_ command: SlashCommand) { submission.fillSlash(command) }

	func send() async {
		reviewOutcomeNotice = nil
		if case .showLanguagePicker? = await submission.send(using: services.coach) {
			languageNotSaved = nil
			showLanguage = true
		}
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
		#if DEBUG
			if case .presented(let ref) = decision, outcome == .presentationRecorded,
				let fixture = services.fixture, let driver = fixture.reviewProofDriver
			{
				await driver.didPresent(ref)
				await driver.refreshIfReady(chat, coach: services.coach, records: fixture.records)
			}
		#endif
		switch decision {
		case .approve, .cancel, .retryRemaining, .checkAgain:
			reviewOutcomeNotice = outcome.notice
		case .presented, .presentationFailed, .showAgain:
			break
		}
	}

	private func observeChat() {
		guard observation == nil else { return }
		let coach = services.coach
		observation = Task { [weak self] in
			for await snapshot in await coach.observe(.main) {
				guard let self, !Task.isCancelled else { return }
				self.chat = snapshot
				#if DEBUG
					if let fixture = services.fixture, let driver = fixture.reviewProofDriver {
						await driver.refreshIfReady(
							snapshot, coach: coach, records: fixture.records)
					}
				#endif
			}
		}
	}
}
