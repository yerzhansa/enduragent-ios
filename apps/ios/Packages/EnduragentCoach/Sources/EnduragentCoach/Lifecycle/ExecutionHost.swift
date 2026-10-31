import Foundation

public protocol ExecutionHost: Sendable {
	func beginLease(
		_ request: LeaseRequest,
		onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) async -> any ExecutionLease
}

public protocol ExecutionLease: Sendable {
	var kind: LeaseKind { get }
	func end(_ ending: LeaseEnding) async
}

public struct LeaseRequest: Sendable, Equatable {
	public let chat: ChatID
	public let initiatedBy: LeaseInitiator

	public init(chat: ChatID, initiatedBy: LeaseInitiator) {
		self.chat = chat
		self.initiatedBy = initiatedBy
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

public enum LeaseEnding: Sendable, Equatable {
	case finished
	case failed
	case interrupted(InterruptionCause)
}

public struct LeaseRecord: Sendable, Equatable, Identifiable {
	public let id: String
	public let request: LeaseRequest
	public let kind: LeaseKind
	public var ending: LeaseEnding?
	public var expiry: ExpiryCause?

	public init(id: String, request: LeaseRequest, kind: LeaseKind) {
		self.id = id
		self.request = request
		self.kind = kind
		self.ending = nil
		self.expiry = nil
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
