import Foundation

public struct SessionSettings: Sendable, Equatable {
	public var historyBudgetRatio: HistoryBudgetRatio
	public var contextWindowOverride: ContextWindowOverride?

	package var effectiveContextWindow: Int {
		min(
			contextWindowOverride?.tokens ?? TurnPolicy.contextWindowCap,
			TurnPolicy.contextWindowCap)
	}

	public static let npmDefaults = SessionSettings(
		historyBudgetRatio: .npmDefault,
		contextWindowOverride: nil
	)

	public func replacing(_ field: SessionField, with text: String)
		throws(SessionSettingRejected) -> SessionSettings
	{
		var next = self
		switch field {
		case .historyBudgetRatio:
			next.historyBudgetRatio = try HistoryBudgetRatio(
				try Self.number(text, for: field) / 100)
		case .contextWindowOverride where Self.isBlank(text):
			next.contextWindowOverride = nil
		case .contextWindowOverride:
			next.contextWindowOverride = try ContextWindowOverride(
				tokens: try Self.whole(text, for: field))
		}
		return next
	}

	public func text(for field: SessionField) -> String {
		switch field {
		case .historyBudgetRatio: historyBudgetRatio.percentText
		case .contextWindowOverride: contextWindowOverride.map { String($0.tokens) } ?? ""
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

	fileprivate var percentText: String {
		let percent = (value * 10_000_000_000).rounded() / 100_000_000
		return percent == percent.rounded() ? String(Int(percent)) : String(percent)
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

public struct SessionSettingRejected: Error, Sendable, Equatable {
	static let safeIntegerLimit = 9_007_199_254_740_991

	public let field: SessionField
	public let reason: CatalogKey

	init(field: SessionField, reason: CatalogKey) {
		self.field = field
		self.reason = reason
	}

	init(_ field: SessionField) {
		self.init(field: field, reason: field.rejection)
	}

	public func sentence(in phrasebook: CatalogPhrasebook) -> String {
		phrasebook.say(reason, [:])
	}
}

public enum SessionField: Sendable, Equatable, Hashable, CaseIterable {
	case historyBudgetRatio
	case contextWindowOverride

	fileprivate var rejection: CatalogKey {
		switch self {
		case .historyBudgetRatio: Catalog.settingsConversationValidationHistoryTokenBudgetRatio
		case .contextWindowOverride: Catalog.settingsConversationValidationContextWindowTokens
		}
	}
}
