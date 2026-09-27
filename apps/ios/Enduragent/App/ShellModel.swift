import EnduragentCoach
import Foundation
import Observation
import StoreKit

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
	var dismissedProposal: Nonce?
	var slashListVisible = false
	private(set) var status: CoachStatus?
	var starterLine: String?
	var starterResolved = false
	var balance: Credits?
	var catalog: PackCatalog?
	var creditsNotice: AthleteNotice?
	private(set) var history: HistoryList = .loading
	private(set) var newConversationUncertain = false
	var errorLine: String?
	var connectKey = ""
	var connectError: String?
	var didConnect = false
	var confirmLine: String?
	var showSidebar = false
	var showCredits = false
	var packPrices: [String: String] = [:]

	let builder: ServicesBuilder
	let lifecycle: AppLifecycle
	let drafts: DraftStore
	private let defaults: UserDefaults
	private var starterLoaded = false
	private var observation: Task<Void, Never>?

	init(builder: ServicesBuilder) {
		self.builder = builder
		self.lifecycle = AppLifecycle(builder: builder)
		self.defaults = builder.defaults
		self.drafts = DraftStore(defaults: builder.defaults)
		if defaults.bool(forKey: Self.onboardingCompletedKey) {
			route = .chat
		}
		draft = drafts.load(.main) ?? Draft(id: DraftID(), text: "")
		if route == .chat {
			observeChat()
		}
	}

	static let onboardingCompletedKey = "enduragent.onboardingCompleted"

	var services: AppServices {
		builder.services
	}

	var phrasebook: any Phrasebook {
		(status?.language ?? .automatic).phrasebook(device: builder.language)
	}

	var languageNotSavedLine: String? {
		languageNotSaved.map {
			$0.notSaved(keeping: status?.language ?? .automatic, in: phrasebook)
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

	var visibleProposal: PendingProposal? {
		guard let pending = chat?.pendingProposal, pending.nonce != dismissedProposal else {
			return nil
		}
		return pending
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
			connectError = nil
			didConnect = true
			await refreshStatus()
		case .kept, .disconnected, .refused, .failedPreviousKept:
			connectError = phrasebook.say(Catalog.connectErrorRejected, [:])
			didConnect = false
		}
	}

	func continueConnect() {
		guard didConnect else { return }
		route = .onboarding(.starter)
	}

	func skipConnect() {
		didConnect = false
		connectError = nil
		route = .onboarding(.starter)
	}

	func loadStarter() async {
		guard !starterLoaded else { return }
		starterLoaded = true
		do {
			let token = try await builder.deviceCheck.token()
			let outcome = try await services.coach.credits.grant(deviceCheck: token)
			switch outcome {
			case .minted(let credits):
				starterLine = "\(credits.units) credits"
			case .toppedUp(let added):
				starterLine = "Added \(added.units) credits"
			case .alreadyGranted:
				starterLine =
					try await existingBalanceLine()
					?? "This device already used its starter credits."
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
		return "\(balance.credits.units) credits"
	}

	func appear() async {
		guard route == .chat else { return }
		observeChat()
		await refreshStatus()
	}

	@discardableResult
	func refreshStatus() async -> CoachStatus {
		let current = await services.coach.status()
		status = current
		return current
	}

	func sceneChanged(_ event: AppLifecycleEvent) async {
		await lifecycle.forward(event)
		guard event == .becameActive, route == .chat else { return }
		await refreshStatus()
	}

	func startChatting() {
		defaults.set(true, forKey: Self.onboardingCompletedKey)
		route = .chat
		observeChat()
	}

	func newConversation() async {
		confirmLine = nil
		errorLine = nil
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
			if services.isFixture {
				packPrices = [:]
			} else {
				let products = try await Product.products(for: loaded.packs.map(\.id))
				packPrices = Dictionary(
					uniqueKeysWithValues: products.map { ($0.id, $0.displayPrice) })
			}
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
		errorLine = nil
		confirmLine = nil
		slashListVisible = false
		if case .rejected(let message)? = await services.fixtureDirector?.prepare(for: text) {
			errorLine = message
			return
		}
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
		await refreshStatus()
	}

	func saveSession(_ settings: SessionSettings) async throws(PreferenceWriteFailure) {
		try await services.coach.setSession(settings)
		await refreshStatus()
	}

	func confirmPending() async {
		guard let pending = visibleProposal, pending.confirmable(under: status) else { return }
		do {
			let outcome = try await services.coach.confirm(chatId: .main, nonce: pending.nonce)
			switch outcome {
			case .executed(let summary):
				errorLine = nil
				confirmLine = "Done — \(summary)."
			case .expired:
				errorLine = nil
				confirmLine = "That proposal expired — ask me again and I'll re-propose."
			case .refused(let message), .failed(let message):
				errorLine = message
			case .mismatch, .none:
				errorLine = String(describing: outcome)
			}
		} catch {
			errorLine = String(describing: error)
		}
	}

	func cancelPending() {
		dismissedProposal = visibleProposal?.nonce
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
