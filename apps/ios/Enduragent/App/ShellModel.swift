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
	private(set) var status: CoachStatus?
	var starterLine: String?
	var starterResolved = false
	var balance: Credits?
	var catalog: PackCatalog?
	var creditsNotice: AthleteNotice?
	var history: [ChatSummary] = []
	var errorLine: String?
	var connectKey = ""
	var connectError: String?
	var didConnect = false
	var confirmLine: String?
	var chatId: ChatID = .main
	var showSidebar = false
	var showCredits = false
	var packPrices: [String: String] = [:]

	let builder: ServicesBuilder
	let lifecycle: AppLifecycle
	let chatIndex: ChatIndex
	let drafts: DraftStore
	private let defaults: UserDefaults
	private var starterLoaded = false
	private var observation: Task<Void, Never>?
	private var observedChat: ChatID?

	init(builder: ServicesBuilder) {
		self.builder = builder
		self.lifecycle = AppLifecycle(builder: builder)
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

	var services: AppServices {
		builder.services
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
			connectError = builder.phrasebook.say(Catalog.connectErrorRejected, [:])
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
			starterLine = AthleteNotice.credits(failure: error).sentence(in: builder.phrasebook)
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
		await reloadHistory()
		await refreshStatus()
	}

	func refreshStatus() async {
		status = await services.coach.status()
	}

	func startChatting() {
		beginChat(ChatID(rawValue: UUID().uuidString.lowercased()))
		saveSession()
		route = .chat
		observeChat()
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
		guard !text.isEmpty, !isSending else { return }
		isSending = true
		defer { isSending = false }
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

	func stop() async {
		await services.coach.stop(chatId)
	}

	func confirmPending() async {
		guard let pending = visibleProposal, pending.confirmable(under: status) else { return }
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
			errorLine = String(describing: error)
		}
	}

	func cancelPending() {
		dismissedProposal = visibleProposal?.nonce
	}

	private func observeChat() {
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
}
