import Foundation
import Synchronization

package final class DiagnosticsLog: Sendable {
	package static let capacity = 200
	package static let detailLimit = 2_000

	private let clock: any Clock
	private let ring = Mutex<[DiagnosticsEntry]>([])

	package init(clock: any Clock) {
		self.clock = clock
	}

	package var entries: [DiagnosticsEntry] {
		ring.withLock { $0 }
	}

	package func record(_ event: DiagnosticsEvent, redacting secrets: [String] = []) {
		let entry = DiagnosticsEntry(at: clock.now, event: event.redacted(secrets))
		ring.withLock { entries in
			entries.append(entry)
			if entries.count > Self.capacity {
				entries.removeFirst(entries.count - Self.capacity)
			}
		}
	}
}

package struct DiagnosticsEntry: Sendable, Equatable {
	package let at: Date
	package let event: DiagnosticsEvent
}

package enum DiagnosticsEvent: Sendable, Equatable {
	case providerFailure(AttemptID, ProviderFailure, detail: String)
	case memoryFlushFailed(ChatID, detail: String)
	case skippedRecord(SkippedRow)

	fileprivate func redacted(_ secrets: [String]) -> DiagnosticsEvent {
		switch self {
		case .providerFailure(let attempt, let failure, let detail):
			return .providerFailure(attempt, failure, detail: Redaction.clean(detail, secrets))
		case .memoryFlushFailed(let chat, let detail):
			return .memoryFlushFailed(chat, detail: Redaction.clean(detail, secrets))
		case .skippedRecord:
			return self
		}
	}
}

private enum Redaction {
	static let marker = "[redacted]"

	static func clean(_ text: String, _ secrets: [String]) -> String {
		var clean = text
		for secret in secrets where !secret.isEmpty {
			clean = clean.replacingOccurrences(of: secret, with: marker)
		}
		clean = clean.replacing(/\bsk-[A-Za-z0-9_\-]{6,}/, with: marker)
		clean = clean.replacing(/(?i)\bbearer\s+[^\s"',;]+/, with: "Bearer \(marker)")
		return String(clean.prefix(DiagnosticsLog.detailLimit))
	}
}
