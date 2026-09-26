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
	var retryRefusal: RetryRefusal?
	var dismissedProposal: Nonce?
	var slashListVisible = false
	var athlete: AthleteProfile?
	var todayWellness: WellnessDay?
	var starterCredits: Credits?
	var starterLine: String?
	var starterResolved = false
	var balance: Credits?
	var catalog: PackCatalog?
	var history: [ChatSummary] = []
	var errorLine: String?
	var connectKey = ""
	var connectError: String?
	var didConnect = false
	var confirmLine: String?
	var chatId: ChatID = .main
	var showSidebar = false
	var packPrices: [String: String] = [:]

	let builder: ServicesBuilder
	let chatIndex: ChatIndex
	let drafts: DraftStore
	private let defaults: UserDefaults
	private var starterLoaded = false
	private var observation: Task<Void, Never>?
	private var observedChat: ChatID?

	init(builder: ServicesBuilder) {
		self.builder = builder
		self.defaults = builder.defaults
		self.chatIndex = ChatIndex(defaults: builder.defaults)
		self.drafts = DraftStore(defaults: builder.defaults)
		restoreSession()
		draft = drafts.load(chatId) ?? Draft(id: DraftID(), text: "")
		if route == .chat {
			observeChat()
		}
	}

	static let onboardingCompletedKey = "enduragent.onboardingCompleted"
	static let lastChatIdKey = "enduragent.lastChatId"

	var services: AppServices? {
		builder.services
	}

	var athleteFirstName: String {
		guard let name = athlete?.name.trimmingCharacters(in: .whitespacesAndNewlines),
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
				starterCredits = credits
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
		starterCredits = balance.credits
		return "\(balance.credits.units) credits"
	}

	func appear() async {
		guard route == .chat else { return }
		do {
			_ = try builder.completedServices()
			observeChat()
			await reloadHistory()
			try await refreshAthlete()
		} catch {
			errorLine = athleteFacing(failureMessage(error))
		}
	}

	func startChatting() {
		do {
			_ = try builder.completedServices()
			beginChat(ChatID(rawValue: UUID().uuidString.lowercased()))
			saveSession()
			route = .chat
			observeChat()
		} catch {
			errorLine = athleteFacing(String(describing: error))
		}
	}

	func newChat() {
		beginChat(ChatID(rawValue: UUID().uuidString.lowercased()))
		saveSession()
		confirmLine = nil
		errorLine = nil
		showSidebar = false
		observeChat()
	}

	func openChat(_ id: ChatID) async {
		chatId = id
		saveSession()
		showSidebar = false
		confirmLine = nil
		errorLine = nil
		draft = drafts.load(chatId) ?? Draft(id: DraftID(), text: "")
		notSent = false
		slashListVisible = false
		observeChat()
	}

	func reloadHistory() async {
		guard let services else {
			history = []
			return
		}
		var rows: [ChatSummary] = []
		for entry in chatIndex.all() {
			guard let id = ChatID(rawValue: entry.id),
				let created = CivilDate(rawValue: entry.created)
			else {
				continue
			}
			var snapshots = await services.coach.observe(id).makeAsyncIterator()
			let turns = await snapshots.next()?.turns ?? []
			let title = turns.lazy.compactMap(\.athleteText).first ?? "New chat"
			rows.append(ChatSummary(id: id, title: title, civilDate: created))
		}
		history = rows
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
		drafts.save(draft, for: chatId)
		updateSlashList()
	}

	func updateSlashList() {
		slashListVisible = draft.text.hasPrefix("/") && !draft.text.contains(where: \.isWhitespace)
	}

	func fillSlash(_ command: SlashCommand) {
		draft.text = command.rawValue + " "
		drafts.save(draft, for: chatId)
		updateSlashList()
	}

	func send() async {
		let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, let services else { return }
		notSent = false
		errorLine = nil
		confirmLine = nil
		slashListVisible = false
		if case .rejected(let message)? = services.fixtureDirector?.prepare(for: text) {
			errorLine = message
			return
		}
		do {
			switch try await services.coach.send(Draft(id: draft.id, text: text), to: chatId) {
			case .accepted, .showLanguagePicker:
				draft = Draft(id: DraftID(), text: "")
				drafts.clear(chatId)
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

	func perform(_ action: RecoveryAction) async {
		guard let services else { return }
		switch action {
		case .tryAgain(let turn):
			if let text = chat?.turns.first(where: { $0.id == turn })?.athleteText {
				services.fixtureDirector?.prepareRetry(of: text)
			}
			do {
				try await services.coach.retry(turn, in: chatId)
				retryRefusal = nil
			} catch {
				retryRefusal = error
			}
		}
	}

	func stop() async {
		await services?.coach.stop(chatId)
	}

	func confirmPending() async {
		guard let services, let pending = visibleProposal else { return }
		do {
			let outcome = try await services.coach.confirm(chatId: chatId, nonce: pending.nonce)
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
			errorLine = athleteFacing(String(describing: error))
		}
	}

	func cancelPending() {
		dismissedProposal = visibleProposal?.nonce
	}

	private func observeChat() {
		guard let services else { return }
		if observedChat == chatId, let observation, !observation.isCancelled {
			return
		}
		observation?.cancel()
		chat = nil
		observedChat = chatId
		let coach = services.coach
		let chat = chatId
		observation = Task { [weak self] in
			for await snapshot in await coach.observe(chat) {
				guard let self, !Task.isCancelled else { return }
				self.chat = snapshot
			}
		}
	}

	private func beginChat(_ id: ChatID?) {
		guard let id else { return }
		chatId = id
		chatIndex.add(id: id, created: CivilDates.today(clock: builder.clock))
		draft = drafts.load(chatId) ?? Draft(id: DraftID(), text: "")
		notSent = false
		slashListVisible = false
	}

	private func restoreSession() {
		let stored = storedChatId()
		let indexed = chatIndex.all().first.flatMap { ChatID(rawValue: $0.id) }
		let completed = defaults.bool(forKey: Self.onboardingCompletedKey)
		guard completed || stored != nil || indexed != nil else { return }
		route = .chat
		if let stored {
			chatId = stored
		} else if let indexed {
			chatId = indexed
		} else {
			chatId = .main
		}
	}

	private func saveSession() {
		defaults.set(true, forKey: Self.onboardingCompletedKey)
		defaults.set(chatId.rawValue, forKey: Self.lastChatIdKey)
	}

	private func storedChatId() -> ChatID? {
		guard let raw = defaults.string(forKey: Self.lastChatIdKey) else { return nil }
		return ChatID(rawValue: raw)
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

	private func athleteFacing(_ message: String) -> String {
		let raw = ["UnknownFinishReasonError", "OpenRouterHTTPError", "ProviderAuthError"]
		guard raw.contains(where: message.hasPrefix) else { return message }
		return builder.phrasebook.say(Catalog.chatNoticeResponseFailure, [:])
	}

	private func grantFailureName(_ error: Error) -> String {
		if let failure = error as? CreditsFailure {
			return String(describing: failure)
		}
		return String(describing: error)
	}
}

struct ChatSummary: Identifiable, Equatable {
	var id: ChatID
	var title: String
	var civilDate: CivilDate
}
