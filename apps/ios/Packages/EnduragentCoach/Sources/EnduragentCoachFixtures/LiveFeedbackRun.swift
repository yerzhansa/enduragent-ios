import EnduragentCoach
import Foundation

package enum LiveFeedbackRefusal: Sendable, Equatable {
	case notSelected
	case alreadyPosted
}

package enum LiveFeedbackRun {
	package static let selector = "feedback"
	package static let header = "time\tid\tanswers\toutcome"
	package static let note =
		"Enduragent iPhone test note from the Milestone 6 build. Please ignore."

	package static func refusal(environment: [String: String], log: Data?) -> LiveFeedbackRefusal? {
		guard environment["ENDURAGENT_LIVE"] == selector else { return .notSelected }
		let lines = String(decoding: log ?? Data(), as: UTF8.self).split(
			whereSeparator: \.isNewline)
		return lines.contains { $0 != header } ? .alreadyPosted : nil
	}

	package static func existingLog(at log: URL) throws -> Data? {
		do {
			return try Data(contentsOf: log)
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			return nil
		}
	}

	package static func run(
		using client: FeedbackClient, environment: [String: String], log: URL, directory: URL
	) async throws -> LiveFeedbackRefusal? {
		let existing = try existingLog(at: log)
		if let refusal = refusal(environment: environment, log: existing) { return refusal }
		let service = SupportService(
			journal: FileJournalStorage(directory: directory),
			keptNotes: FileKeptNoteStorage(directory: directory),
			shareFolder: ShareFolder(in: directory), feedback: client, app: .fixture,
			device: .fixture)
		let diagnostics = service.openLog(clock: SystemClock())
		let support = Support(
			log: diagnostics, service: service,
			census: SupportCensus(
				status: {
					StatusFacts(
						access: .none, training: .unconnected, language: LanguageCode(.automatic))
				},
				records: { .unavailable(.unavailable) }))
		let sent = try await support.sendNote(note)
		let row = [
			diagnostics.clock.now.formatted(.iso8601), sent.id.rawValue,
			sent.answers.map(\.code.rawValue).joined(separator: ","), outcome(sent.outcome),
		].joined(separator: "\t")
		var text = String(decoding: existing ?? Data(), as: UTF8.self)
		if text.isEmpty { text = header }
		if !text.hasSuffix("\n") { text += "\n" }
		try FileManager.default.createDirectory(
			at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data((text + row + "\n").utf8).write(to: log, options: .atomic)
		return nil
	}

	private static func outcome(_ outcome: FeedbackOutcome) -> String {
		switch outcome {
		case .received: "received"
		case .notSent(let reason): "notSent." + reason.rawValue
		case .notConfirmed: "notConfirmed"
		}
	}
}
