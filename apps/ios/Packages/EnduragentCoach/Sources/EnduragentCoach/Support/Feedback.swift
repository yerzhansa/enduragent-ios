import Foundation

package struct FeedbackText: Sendable, Hashable, Codable {
	private static let javaScriptWhitespace: Set<Unicode.Scalar> = [
		"\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}", "\u{00A0}",
		"\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
		"\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}",
		"\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}",
	]

	package let trimmed: String

	package init(validating raw: String) throws(FeedbackRefusal) {
		let trimmed = Self.trimmedAsJavaScript(raw)
		guard !trimmed.isEmpty else { throw .empty }
		guard !trimmed.unicodeScalars.contains("\u{0000}") else { throw .containsNul }
		let units = trimmed.utf16.count
		guard units <= FeedbackRefusal.limit else { throw .tooLong(units: units) }
		self.trimmed = trimmed
	}

	package init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		let raw = try container.decode(String.self)
		do {
			self = try FeedbackText(validating: raw)
		} catch {
			throw DecodingError.dataCorrupted(
				.init(
					codingPath: decoder.codingPath,
					debugDescription: "The kept feedback text is refused.",
					underlyingError: error))
		}
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(trimmed)
	}

	package static func trimmedAsJavaScript(_ raw: String) -> String {
		let scalars = raw.unicodeScalars
		guard let first = scalars.firstIndex(where: { !javaScriptWhitespace.contains($0) }),
			let last = scalars.lastIndex(where: { !javaScriptWhitespace.contains($0) })
		else { return "" }
		return String(String.UnicodeScalarView(scalars[first...last]))
	}
}

public enum FeedbackRefusal: Error, Sendable, Equatable {
	public static let limit = 4_000

	case empty
	case containsNul
	case tooLong(units: Int)
}

package struct FeedbackID: Sendable, Hashable, Codable {
	package let rawValue: String

	private init(rawValue: String) {
		self.rawValue = rawValue
	}

	fileprivate static func mint() -> FeedbackID {
		FeedbackID(rawValue: UUID().uuidString.lowercased())
	}

	package init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		let raw = try container.decode(String.self)
		let workerPattern = /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/
		guard raw.wholeMatch(of: workerPattern) != nil else {
			throw DecodingError.dataCorruptedError(
				in: container, debugDescription: "The kept feedback id is not a lowercase UUID v4.")
		}
		rawValue = raw
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}
}

package struct FeedbackNote: Sendable, Equatable, Codable {
	package let id: FeedbackID
	package let text: FeedbackText

	package static func first(_ text: FeedbackText) -> FeedbackNote {
		FeedbackNote(id: .mint(), text: text)
	}

	package func revised(to text: FeedbackText) -> FeedbackNote {
		text == self.text ? self : .first(text)
	}

	private init(id: FeedbackID, text: FeedbackText) {
		self.id = id
		self.text = text
	}
}

package struct FeedbackBody: Sendable, Encodable {
	package let channel: FeedbackChannel
	package let id: FeedbackID
	package let text: FeedbackText

	package init(_ note: FeedbackNote) {
		channel = .ios
		id = note.id
		text = note.text
	}
}

package enum FeedbackChannel: String, Sendable, Encodable {
	case ios
}

public struct FeedbackReceipt: Sendable, Equatable {
	fileprivate init() {}
}

package enum AttemptAnswer: Sendable, Equatable {
	case stored(FeedbackReceipt)
	case unavailable
	case limited
	case refused(status: Int)
	case redirected(status: Int)
	case neverLeft(URLError.Code)
	case mayHaveLeft(MayHaveLeft)

	package init(status: Int) {
		switch status {
		case 204: self = .stored(FeedbackReceipt())
		case 503: self = .unavailable
		case 429: self = .limited
		case 300...399: self = .redirected(status: status)
		case 500...599: self = .mayHaveLeft(.serverStatus(status))
		default: self = .refused(status: status)
		}
	}

	package init(error: any Error) {
		guard let failure = error as? URLError else {
			self = .mayHaveLeft(.otherError(FailureCode(error)))
			return
		}
		switch Leg.of(failure.code) {
		case .neverLeft: self = .neverLeft(failure.code)
		case .mayHaveLeft: self = .mayHaveLeft(.transport(failure.code))
		}
	}

	package var retried: Bool {
		switch self {
		case .unavailable, .redirected, .neverLeft, .mayHaveLeft(.transport),
			.mayHaveLeft(.otherError):
			true
		case .stored, .limited, .refused, .mayHaveLeft(.serverStatus): false
		}
	}
}

package enum MayHaveLeft: Sendable, Equatable {
	case serverStatus(Int)
	case transport(URLError.Code)
	case otherError(FailureCode)
}

package enum Leg: Sendable {
	case neverLeft
	case mayHaveLeft

	private static let beforeTheBody: Set<URLError.Code> = [
		.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
		.dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed,
		.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
		.serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
		.appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL,
	]

	package static func of(_ code: URLError.Code) -> Leg {
		beforeTheBody.contains(code) ? .neverLeft : .mayHaveLeft
	}
}

public enum FeedbackOutcome: Sendable, Equatable {
	case received(FeedbackReceipt)
	case notSent(NotSentReason)
	case notConfirmed
}

public enum NotSentReason: String, Sendable, Equatable, Codable {
	case noConnection
	case busy
	case refused
	case stopped
}

package enum FeedbackDelivery {
	package static let maxAttempts = 2

	package static func shouldRetry(after answers: [AttemptAnswer]) -> Bool {
		answers.count < maxAttempts && answers.last?.retried == true
	}

	package static func settle(prior: KeptPhase?, answers: [AttemptAnswer]) -> FeedbackOutcome {
		let alone = answers.map(outcome(of:))
		for case .received(let receipt) in alone {
			return .received(receipt)
		}
		let earlierMayHaveLeft = prior == .sending || prior == .notConfirmed
		guard !earlierMayHaveLeft, !alone.contains(.notConfirmed), let newest = alone.last else {
			return .notConfirmed
		}
		return newest
	}

	private static func outcome(of answer: AttemptAnswer) -> FeedbackOutcome {
		switch answer {
		case .stored(let receipt): .received(receipt)
		case .neverLeft: .notSent(.noConnection)
		case .unavailable, .limited: .notSent(.busy)
		case .refused, .redirected: .notSent(.refused)
		case .mayHaveLeft: .notConfirmed
		}
	}
}

package struct KeptNote: Sendable, Equatable, Codable {
	package let note: FeedbackNote
	package var phase: KeptPhase
}

package enum KeptPhase: Sendable, Equatable, Codable {
	case ready
	case sending
	case notSent(NotSentReason)
	case notConfirmed

	package var afterRelaunch: KeptPhase {
		switch self {
		case .ready: .notSent(.stopped)
		case .sending: .notConfirmed
		case .notSent, .notConfirmed: self
		}
	}
}
