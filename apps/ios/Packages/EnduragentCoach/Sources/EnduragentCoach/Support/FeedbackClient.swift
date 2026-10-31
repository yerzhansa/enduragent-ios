import Foundation

package struct FeedbackClient: Sendable {
	package static let endpoint: URL = {
		guard let url = URL(string: "https://feedback.enduragent.icu/v1/feedback") else {
			fatalError("The feedback endpoint is invalid")
		}
		return url
	}()
	package static let attemptTimeout: TimeInterval = 10
	package static var live: FeedbackClient { FeedbackClient(protocolClasses: []) }

	package let session: URLSession

	package init(protocolClasses: [AnyClass]) {
		session = ephemeralSession(
			requestTimeout: Self.attemptTimeout, resourceTimeout: Self.attemptTimeout,
			protocolClasses: protocolClasses)
	}

	package static func body(of note: FeedbackNote) throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(FeedbackBody(note))
	}

	package func deliver(_ note: FeedbackNote) async -> [AttemptAnswer] {
		var answers: [AttemptAnswer] = []
		repeat {
			answers.append(await attempt(note))
		} while FeedbackDelivery.shouldRetry(after: answers)
		return answers
	}

	private func attempt(_ note: FeedbackNote) async -> AttemptAnswer {
		do {
			var request = URLRequest(url: Self.endpoint)
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = try Self.body(of: note)
			let (_, response) = try await session.data(for: request, delegate: RejectRedirects())
			guard let http = response as? HTTPURLResponse else {
				return AttemptAnswer(error: URLError(.badServerResponse))
			}
			return AttemptAnswer(status: http.statusCode)
		} catch {
			return AttemptAnswer(error: error)
		}
	}
}

package protocol KeptNoteStorage: Sendable {
	func load() throws -> KeptNote?
	func save(_ kept: KeptNote) throws
	func clear() throws
}

package struct FileKeptNoteStorage: KeptNoteStorage {
	package let file: URL

	package init(directory: URL) {
		file = directory.appending(path: "feedback-note.json")
	}

	package func load() throws -> KeptNote? {
		let data: Data
		do {
			data = try Data(contentsOf: file)
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			return nil
		}
		return try JSONDecoder().decode(KeptNote.self, from: data)
	}

	package func save(_ kept: KeptNote) throws {
		try FileManager.default.createDirectory(
			at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try JSONEncoder().encode(kept).write(to: file, options: .atomic)
	}

	package func clear() throws {
		do {
			try FileManager.default.removeItem(at: file)
		} catch let error as CocoaError where error.code == .fileNoSuchFile {
			return
		}
	}
}
