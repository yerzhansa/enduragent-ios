import Foundation

public struct SessionSettings: Sendable, Equatable {
	public var historyBudgetRatio: HistoryBudgetRatio
	public var idleReset: IdleReset
	public var dailyResetHour: DailyResetHour
	public var archiveRetention: ArchiveRetention
	public var timeZone: SessionTimeZone
	public var contextWindowOverride: ContextWindowOverride?
	public var compactionModel: ModelSelection
	public var flushModel: ModelSelection

	public static let npmDefaults = SessionSettings(
		historyBudgetRatio: .npmDefault,
		idleReset: .off,
		dailyResetHour: .npmDefault,
		archiveRetention: .forever,
		timeZone: .device,
		contextWindowOverride: nil,
		compactionModel: .sameAsResponse,
		flushModel: .sameAsResponse
	)

	public func replacing(_ field: SessionField, with text: String)
		throws(SessionSettingRejected) -> SessionSettings
	{
		var next = self
		switch field {
		case .historyBudgetRatio:
			next.historyBudgetRatio = try HistoryBudgetRatio(
				try Self.number(text, for: field))
		case .idleReset:
			next.idleReset = try IdleReset(minutes: try Self.whole(text, for: field))
		case .dailyResetHour:
			next.dailyResetHour = try DailyResetHour(try Self.whole(text, for: field))
		case .archiveRetention:
			next.archiveRetention = try ArchiveRetention(days: try Self.whole(text, for: field))
		case .timeZone:
			next.timeZone = try SessionTimeZone(text: text)
		case .contextWindowOverride where Self.isBlank(text):
			next.contextWindowOverride = nil
		case .contextWindowOverride:
			next.contextWindowOverride = try ContextWindowOverride(
				tokens: try Self.whole(text, for: field))
		case .compactionModel, .flushModel:
			let selection = try ModelSelection(text: text, field: field)
			if field == .compactionModel {
				next.compactionModel = selection
			} else {
				next.flushModel = selection
			}
		}
		return next
	}

	public func text(for field: SessionField) -> String {
		switch field {
		case .historyBudgetRatio: String(historyBudgetRatio.value)
		case .idleReset: String(idleReset.minutes)
		case .dailyResetHour: String(dailyResetHour.hour)
		case .archiveRetention: String(archiveRetention.days)
		case .timeZone: timeZone.text
		case .contextWindowOverride: contextWindowOverride.map { String($0.tokens) } ?? ""
		case .compactionModel: compactionModel.text
		case .flushModel: flushModel.text
		}
	}

	private static func isBlank(_ text: String) -> Bool {
		text.trimmingCharacters(in: .whitespaces).isEmpty
	}

	private static func number(_ text: String, for field: SessionField)
		throws(SessionSettingRejected) -> Double
	{
		guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else {
			throw SessionSettingRejected(field)
		}
		return value
	}

	private static func whole(_ text: String, for field: SessionField)
		throws(SessionSettingRejected) -> Int
	{
		guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
			throw SessionSettingRejected(field)
		}
		return value
	}
}

public struct HistoryBudgetRatio: Sendable, Equatable {
	public let value: Double
	public static let npmDefault = HistoryBudgetRatio(unchecked: 0.3)

	public init(_ value: Double) throws(SessionSettingRejected) {
		guard value.isFinite, value > 0, value <= 1 else {
			throw SessionSettingRejected(.historyBudgetRatio)
		}
		self.value = value
	}

	private init(unchecked value: Double) {
		self.value = value
	}
}

public enum IdleReset: Sendable, Equatable {
	case off
	case after(minutes: Int)

	public init(minutes: Int) throws(SessionSettingRejected) {
		guard (0...SessionSettingRejected.safeIntegerLimit).contains(minutes) else {
			throw SessionSettingRejected(.idleReset)
		}
		self = minutes == 0 ? .off : .after(minutes: minutes)
	}

	public var minutes: Int {
		switch self {
		case .off: 0
		case .after(let minutes): minutes
		}
	}
}

public struct DailyResetHour: Sendable, Equatable {
	public let hour: Int
	public static let npmDefault = DailyResetHour(unchecked: 4)

	public init(_ hour: Int) throws(SessionSettingRejected) {
		guard (0...23).contains(hour) else {
			throw SessionSettingRejected(.dailyResetHour)
		}
		self.hour = hour
	}

	private init(unchecked hour: Int) {
		self.hour = hour
	}
}

public enum ArchiveRetention: Sendable, Equatable {
	case forever
	case days(Int)

	public init(days: Int) throws(SessionSettingRejected) {
		guard (0...SessionSettingRejected.safeIntegerLimit).contains(days) else {
			throw SessionSettingRejected(.archiveRetention)
		}
		self = days == 0 ? .forever : .days(days)
	}

	public var days: Int {
		switch self {
		case .forever: 0
		case .days(let days): days
		}
	}
}

public enum SessionTimeZone: Sendable, Equatable {
	case device
	case fixed(IANATimeZone)

	public init(text: String) throws(SessionSettingRejected) {
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else {
			self = .device
			return
		}
		guard !ModelSelection.hasControlCharacters(trimmed), trimmed.utf16.count <= 512,
			let zone = IANATimeZone(identifier: trimmed)
		else {
			throw SessionSettingRejected(.timeZone)
		}
		self = .fixed(zone)
	}

	public var text: String {
		switch self {
		case .device: ""
		case .fixed(let zone): zone.identifier
		}
	}
}

public struct ContextWindowOverride: Sendable, Equatable {
	public let tokens: Int

	public init(tokens: Int) throws(SessionSettingRejected) {
		guard (1...SessionSettingRejected.safeIntegerLimit).contains(tokens) else {
			throw SessionSettingRejected(.contextWindowOverride)
		}
		self.tokens = tokens
	}
}

public enum ModelSelection: Sendable, Equatable {
	case sameAsResponse
	case model(ModelID)

	static let maxLength = 512

	init(text: String, field: SessionField) throws(SessionSettingRejected) {
		if Self.hasControlCharacters(text) {
			throw SessionSettingRejected(
				field: field, reason: Catalog.settingsCoachValidationModelControlCharacters)
		}
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else {
			self = .sameAsResponse
			return
		}
		guard trimmed.utf16.count <= Self.maxLength else {
			throw SessionSettingRejected(
				field: field, reason: Catalog.settingsCoachValidationModelTooLong)
		}
		self = .model(ModelID(rawValue: trimmed))
	}

	public var text: String {
		switch self {
		case .sameAsResponse: ""
		case .model(let model): model.rawValue
		}
	}

	package func resolve(response: ModelID) -> ModelID {
		switch self {
		case .sameAsResponse: response
		case .model(let model): model
		}
	}

	static func hasControlCharacters(_ text: String) -> Bool {
		text.unicodeScalars.contains { $0.value <= 31 || (127...159).contains($0.value) }
	}
}

public struct SessionSettingRejected: Error, Sendable, Equatable {
	static let safeIntegerLimit = 9_007_199_254_740_991
	static let exampleTimeZone = "Europe/London"

	public let field: SessionField
	public let reason: CatalogKey

	init(field: SessionField, reason: CatalogKey) {
		self.field = field
		self.reason = reason
	}

	init(_ field: SessionField) {
		self.init(field: field, reason: field.rejection)
	}

	public func sentence(in phrasebook: any Phrasebook) -> String {
		phrasebook.say(reason, ["timezone": Self.exampleTimeZone])
	}
}

public enum SessionField: Sendable, Equatable, Hashable, CaseIterable {
	case historyBudgetRatio
	case idleReset
	case dailyResetHour
	case archiveRetention
	case timeZone
	case contextWindowOverride
	case compactionModel
	case flushModel

	fileprivate var rejection: CatalogKey {
		switch self {
		case .historyBudgetRatio: Catalog.settingsConversationValidationHistoryTokenBudgetRatio
		case .idleReset: Catalog.settingsConversationValidationIdleMinutes
		case .dailyResetHour: Catalog.settingsConversationValidationDailyResetHour
		case .archiveRetention: Catalog.settingsConversationValidationResetArchiveRetentionDays
		case .timeZone: Catalog.settingsConversationValidationTimezone
		case .contextWindowOverride: Catalog.settingsConversationValidationContextWindowTokens
		case .compactionModel, .flushModel: Catalog.settingsCoachValidationModelControlCharacters
		}
	}
}

package struct ModelRoles: Sendable, Equatable {
	package let chat: ModelID
	package let compaction: ModelID
	package let flush: ModelID
	package let chatWindow: Int

	package init(response: ModelID, session: SessionSettings) {
		self.chat = response
		self.compaction = session.compactionModel.resolve(response: response)
		self.flush = session.flushModel.resolve(response: response)
		self.chatWindow = min(
			session.contextWindowOverride?.tokens ?? TurnPolicy.contextWindowCap,
			TurnPolicy.contextWindowCap)
	}
}

extension ResolvedAccess {
	package func using(model: ModelID) -> ResolvedAccess {
		ResolvedAccess(credential: credential, model: model)
	}
}
