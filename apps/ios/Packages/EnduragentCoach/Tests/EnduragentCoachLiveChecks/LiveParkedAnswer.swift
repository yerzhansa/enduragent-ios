import Foundation

@testable import EnduragentCoach

struct LiveRawReads: Sendable {
	var profile: JSONValue?
	var wellness: JSONValue?
	var activities: JSONValue?
	var details: [JSONValue] = []
	var streams: TappedResponse?
	var unknownChannel: LiveReadOutcome?
	var unknownChannelName = ""
	var askedChannels: [String] = []
}

struct LiveReadOutcome: Sendable {
	let responses: [TappedResponse]
	let given: JSONValue?

	var threw: Bool { given == nil }
	var answer: TappedResponse? { threw ? nil : responses.last }
}

struct DecodingSite: Sendable, Equatable {
	static let sources = (0..<3).reduce(URL(fileURLWithPath: #filePath)) { path, _ in
		path.deletingLastPathComponent()
	}.appending(path: "Sources/EnduragentCoach")

	let file: String
	let anchor: String

	init(_ file: String, _ anchor: String) {
		self.file = file
		self.anchor = anchor
	}

	var citation: String {
		let text: String
		do {
			text = try String(contentsOf: Self.sources.appending(path: file), encoding: .utf8)
		} catch {
			return "\(file) could not be read (\(error.localizedDescription))"
		}
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
		guard let index = lines.firstIndex(where: { $0.contains(anchor) }) else {
			return "\(file) no longer holds `\(anchor)`"
		}
		return "\(file):\(index + 1)"
	}
}

struct ParkedAnswer: Sendable, Equatable {
	let question: String
	let evidence: [String]
	let decoding: [DecodingSite]
	let verdict: String

	var markdown: String {
		let sites = "Decoding code: " + decoding.map(\.citation).joined(separator: ", ")
		return
			(["## \(question)", ""] + (evidence + [sites]).map { "- \($0)" } + [
				"", "Verdict: \(verdict)", "",
			]).joined(separator: "\n")
	}
}
