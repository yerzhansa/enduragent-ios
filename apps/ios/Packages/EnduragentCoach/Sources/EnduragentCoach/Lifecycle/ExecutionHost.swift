import Foundation

public protocol ExecutionHost: Sendable {
	func beginLease(
		_ request: LeaseRequest,
		onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) async -> any ExecutionLease
}

public protocol ExecutionLease: Sendable {
	var kind: LeaseKind { get }
	func report(_ progress: LeaseProgress) async
	func end(_ ending: LeaseEnding) async
}

public struct LeaseRequest: Sendable, Equatable {
	public let chat: ChatID
	public let initiatedBy: LeaseInitiator
	public let title: CatalogKey
	public let language: LanguageTag

	public init(
		chat: ChatID, initiatedBy: LeaseInitiator, title: CatalogKey, language: LanguageTag
	) {
		self.chat = chat
		self.initiatedBy = initiatedBy
		self.title = title
		self.language = language
	}

	public var titleText: String {
		language.phrasebook.say(title)
	}
}

public enum LeaseInitiator: String, Sendable, Equatable {
	case athlete
	case recovery
}

public enum LeaseKind: String, Sendable, Equatable {
	case continuedProcessing
	case gracePeriodOnly
}

public enum ExpiryCause: String, Sendable, Equatable {
	case systemExpired
	case graceEnded
}

public struct LeaseProgress: Sendable, Equatable {
	public let settledTurns: Int
	public let totalTurns: Int
	public let step: Int
	public let stepLimit: Int

	public init(settledTurns: Int, totalTurns: Int, step: Int, stepLimit: Int) {
		self.settledTurns = settledTurns
		self.totalTurns = totalTurns
		self.step = step
		self.stepLimit = stepLimit
	}
}

public enum LeaseEnding: Sendable, Equatable {
	case finished(CompletionNotice?)
	case interrupted
}

public struct CompletionNotice: Sendable, Equatable {
	public static let excerptLimit = 160

	public let title: CatalogKey
	public let excerpt: String
	public let turn: TurnID
	public let language: LanguageTag

	package init(reply: String, turn: TurnID, language: LanguageTag) {
		self.title = Catalog.archiveCoach
		self.excerpt = String(
			reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.excerptLimit))
		self.turn = turn
		self.language = language
	}

	public var titleText: String {
		language.phrasebook.say(title)
	}
}

public struct LeaseRecord: Sendable, Equatable, Identifiable {
	public let id: String
	public let request: LeaseRequest
	public let kind: LeaseKind
	public var progress: LeaseProgress?
	public var ending: LeaseEnding?
	public var expiry: ExpiryCause?
	public var notes: [String]

	public init(id: String, request: LeaseRequest, kind: LeaseKind) {
		self.id = id
		self.request = request
		self.kind = kind
		self.progress = nil
		self.ending = nil
		self.expiry = nil
		self.notes = []
	}
}

extension InterruptionCause {
	package init(_ expiry: ExpiryCause) {
		switch expiry {
		case .systemExpired: self = .systemExpired
		case .graceEnded: self = .graceEnded
		}
	}
}
