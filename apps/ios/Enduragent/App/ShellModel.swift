import EnduragentCoach
import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class ShellModel {
	var route: ShellRoute = .onboarding(.notice)
	private(set) var chat: ChatSnapshot?
	var draft = Draft(id: DraftID(), text: "")
	var notSent = false
	private(set) var isSending = false
	var dismissedProposal: Nonce?
	var slashListVisible = false
	var athlete: AthleteProfile?
	var todayWellness: WellnessDay?
	var starterLine: String?
	var starterResolved = false
	var balance: Credits?
	var catalog: PackCatalog?
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

	var services: AppServices? {
		builder.services
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
		do {
			let result = try await builder.connectIntervals(apiKey: connectKey)
			athlete = result.athlete
			todayWellness = result.wellness
			connectError = nil
			didConnect = true
		} catch {
			connectError = "intervals.icu did not accept that key"
			didConnect = false
		}
	}

	func continueConnect() {
		guard didConnect else { return }
		route = .onboarding(.starter)
	}

	func skipConnect() {
		athlete = nil
		todayWellness = nil
		didConnect = false
		connectError = nil
		route = .onboarding(.starter)
	}

	func loadStarter() async {
		guard !starterLoaded else { return }
		starterLoaded = true
		do {
			let token = try await builder.deviceCheck.token()
			let outcome = try await builder.credits.grant(deviceCheck: token)
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
			starterLine = grantFailureName(error)
		}
		starterResolved = true
	}

	private func existingBalanceLine() async throws -> String? {
		guard try builder.secrets.openRouterKey() != nil else { return nil }
		let scale = try await builder.credits.catalog().scale
		let balance = try await builder.credits.balance(scale: scale)
		return "\(balance.credits.units) credits"
	}

	func appear() async {
		guard route == .chat else { return }
		do {
			_ = try builder.completedServices()
			observeChat()
			try await refreshAthlete()
		} catch {
			errorLine = failureMessage(error)
		}
	}

	func startChatting() {
		do {
			_ = try builder.completedServices()
			defaults.set(true, forKey: Self.onboardingCompletedKey)
			route = .chat
			observeChat()
		} catch {
			errorLine = String(describing: error)
		}
	}

	func newConversation() async {
		guard let services else { return }
		confirmLine = nil
		errorLine = nil
		showNewConversation(await services.coach.startNewConversation(in: .main))
	}

	func loadHistory() async {
		guard let services else { return }
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
		guard let services else { return }
		do {
			let loaded = try await services.credits.catalog()
			catalog = loaded
			let held = try await services.credits.balance(scale: loaded.scale)
			balance = held.credits
			if services.isFixture {
				packPrices = [:]
			} else {
				let products = try await Product.products(for: loaded.packs.map(\.id))
				packPrices = Dictionary(
					uniqueKeysWithValues: products.map { ($0.id, $0.displayPrice) })
			}
		} catch {
			errorLine = String(describing: error)
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
		guard !text.isEmpty, !isSending, let services else { return }
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
			case .accepted, .showLanguagePicker:
				clear(sent)
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
		await services?.coach.stop(.main)
	}

	func confirmPending() async {
		guard let services, let pending = visibleProposal else { return }
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
		guard let services, observation == nil else { return }
		let coach = services.coach
		observation = Task { [weak self] in
			for await snapshot in await coach.observe(.main) {
				guard let self, !Task.isCancelled else { return }
				self.chat = snapshot
			}
		}
	}

	private func refreshAthlete() async throws {
		guard let services else { return }
		athlete = try await services.intervals.fetchAthlete()
		let today = CivilDates.today(clock: builder.clock)
		todayWellness = try await services.intervals.fetchWellness(oldest: today, newest: today)
			.first
	}

	private func failureMessage(_ error: Error) -> String {
		if let intervals = error as? IntervalsError {
			return intervals.details
		}
		return String(describing: error)
	}

	private func grantFailureName(_ error: Error) -> String {
		if let failure = error as? CreditsFailure {
			return String(describing: failure)
		}
		return String(describing: error)
	}
}
