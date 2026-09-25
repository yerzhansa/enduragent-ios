import EnduragentCoach
import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class ShellModel {
	var route: ShellRoute = .onboarding(.notice)
	var seam: ViewSeam = .empty
	var composer = ""
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
	private let defaults: UserDefaults
	private let persistSession: Bool
	private var starterLoaded = false

	init(
		builder: ServicesBuilder,
		defaults: UserDefaults = .standard,
		persistSession: Bool? = nil
	) {
		self.builder = builder
		self.defaults = defaults
		self.persistSession = persistSession ?? !builder.isFixture
		self.chatIndex = ChatIndex(isFixture: builder.isFixture, defaults: defaults)
		restoreSessionIfNeeded()
	}

	var isWaitingForCoach: Bool {
		seam.phase == .streaming && seam.streamingText.isEmpty
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
		guard persistSession, route == .chat else { return }
		do {
			let services = try builder.completedServices()
			await refreshSeam(from: services)
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
		} catch {
			errorLine = athleteFacing(String(describing: error))
		}
	}

	func newChat() {
		beginChat(ChatID(rawValue: UUID().uuidString.lowercased()))
		saveSession()
		seam = .empty
		confirmLine = nil
		errorLine = nil
		composer = ""
		slashListVisible = false
		showSidebar = false
	}

	func openChat(_ id: ChatID) async {
		chatId = id
		saveSession()
		showSidebar = false
		confirmLine = nil
		errorLine = nil
		composer = ""
		slashListVisible = false
		if let services {
			await refreshSeam(from: services)
		} else {
			seam = .empty
		}
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
			let messages = await services.coach.history(chatId: id)
			let title = messages.first(where: { $0.role == .user })?.text ?? "New chat"
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

	func updateSlashList() {
		slashListVisible = composer.hasPrefix("/") && !composer.contains(where: \.isWhitespace)
	}

	func fillSlash(_ command: SlashCommand) {
		composer = command.rawValue + " "
		updateSlashList()
	}

	func send(_ text: String) async {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		guard let services else { return }
		errorLine = nil
		confirmLine = nil
		if SlashRouting.parse(trimmed) == .plan {
			errorLine = "Plans arrive in the next TestFlight."
			return
		}
		composer = ""
		slashListVisible = false
		if let transport = services.fixtureTransport {
			transport.script = FirstWeekFixture.script(for: trimmed)
		}
		seam = seam.postingUser(
			ChatMessage(
				role: .user,
				text: trimmed,
				civilDate: CivilDates.today(clock: builder.clock)
			)
		)
		await Task.yield()
		do {
			for try await event in services.coach.send(trimmed, chatId: chatId) {
				switch event {
				case .finished, .interrupted:
					await refreshSeam(from: services)
				case .failed(let message):
					seam = seam.applying(event)
					errorLine = athleteFacing(message)
				default:
					seam = seam.applying(event)
				}
				await Task.yield()
			}
		} catch {
			let message = String(describing: error)
			seam = seam.applying(.failed(message: message))
			errorLine = athleteFacing(message)
		}
	}

	func confirmPending() async {
		guard let services, let pending = seam.pendingWrite else { return }
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
			await refreshSeam(from: services)
		} catch {
			errorLine = athleteFacing(String(describing: error))
		}
	}

	func cancelPending() {
		seam.pendingWrite = nil
		if seam.phase == .awaitingConfirmation {
			seam.phase = .idle
		}
	}

	private func beginChat(_ id: ChatID?) {
		guard let id else { return }
		chatId = id
		chatIndex.add(id: id, created: CivilDates.today(clock: builder.clock))
	}

	private func restoreSessionIfNeeded() {
		guard persistSession else { return }
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
		guard persistSession else { return }
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

	private func refreshSeam(from services: AppServices) async {
		var next = await services.coach.snapshot(chatId: chatId)
		next.streamingText = ""
		seam = next
	}

	private func failureMessage(_ error: Error) -> String {
		if let intervals = error as? IntervalsError {
			return intervals.details
		}
		return String(describing: error)
	}

	private func athleteFacing(_ message: String) -> String {
		let failure = builder.phrasebook.say(Catalog.chatNoticeResponseFailure, [:])
		switch message {
		case "CHAT_TTFT_TIMEOUT", "CHAT_INTER_CHUNK_TIMEOUT", "CHAT_PROVIDER_ERROR":
			return failure
		default:
			if message.hasPrefix("UnknownFinishReasonError")
				|| message.hasPrefix("OpenRouterHTTPError")
				|| message.hasPrefix("ProviderAuthError")
			{
				return failure
			}
			return message
		}
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
