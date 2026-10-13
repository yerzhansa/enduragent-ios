import CryptoKit
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct KnowledgeTopicsTests {
	static let topicsThatDifferFromNpm: Set<String> = [
		"cycling-periodization", "cycling-prescription-posture", "cycling-race-prep",
	]

	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	@Test func requestHoldsEveryBundledTopicWholeUnderItsOwnHeading() async throws {
		let system = try await systemPromptOfATurn()
		let bundled = try bundledTopics()

		#expect(bundled.count == 8)
		for (key, text) in bundled {
			#expect(
				system.contains("## Skill: \(key)\n\n\(text)" + PromptAssembly.sectionSeparator),
				"\(key) is not in the request with its whole bundled text")
		}
	}

	@Test func topicKeysAreExactlyTheBundledFilesTheRequestHeadingsAndNpmsTopics() async throws {
		let system = try await systemPromptOfATurn()
		let headings = system.components(separatedBy: "\n")
			.filter { $0.hasPrefix("## Skill:") }
			.map { String($0.dropFirst("## Skill: ".count)) }

		#expect(PromptAssembly.skillKeys.count == 8)
		#expect(headings == PromptAssembly.skillKeys)
		#expect(try bundledTopics().keys.sorted() == PromptAssembly.skillKeys)
		#expect(try npmRecord().keys.sorted() == PromptAssembly.skillKeys)
	}

	@Test(arguments: PromptAssembly.skillKeys)
	func bundledTopicEqualsNpmOnceItsRecordedDifferencesAreApplied(key: String) throws {
		let record = try #require(try npmRecord()[key])
		let bundled = try #require(try bundledTopics()[key])

		#expect(record.differences.isEmpty != Self.topicsThatDifferFromNpm.contains(key))
		guard !record.differences.isEmpty else {
			#expect(sha256(bundled) == record.npmSHA256)
			return
		}
		var expected = try #require(try npmCopies()[key])
		#expect(sha256(expected) == record.npmSHA256)
		for difference in record.differences {
			let parts = expected.components(separatedBy: difference.npm)
			try #require(
				parts.count == 2,
				"the recorded npm passage occurs \(parts.count - 1) times in \(key)")
			expected = parts.joined(separator: difference.phone)
		}
		#expect(bundled == expected)
	}

	@Test func toolListOfATurnNamesNoKnowledgeTopic() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Ride easy."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store)

		_ = try await coach.sendAndSettle("How should I pace a climb?")

		let tools = try #require(transport.requests.first?.tools)
		#expect(tools.map(\.name).contains(.intervalsFetchActivities))
		for tool in tools {
			for word in ["skill", "knowledge", "topic"] {
				#expect(!tool.name.rawValue.contains(word), "\(tool.name.rawValue) names \(word)")
			}
			let offered = tool.description + tool.parameters.canonicalDigestInput()
			for key in PromptAssembly.skillKeys + ["Skill:", "Domain Knowledge"] {
				#expect(!offered.contains(key), "\(tool.name.rawValue) names \(key)")
			}
		}
	}

	private func systemPromptOfATurn() async throws -> String {
		transport.respond = ScriptedReply.sequence(
			[.text("Ride easy."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store)

		_ = try await coach.sendAndSettle("How should I pace a climb?")

		let system = try #require(transport.requests.first?.messages.first)
		try #require(system.role == .system)
		return system.content
	}

	private func bundledTopics() throws -> [String: String] {
		let coachBundle = try #require(
			Bundle(
				url: Bundle.module.bundleURL.deletingLastPathComponent()
					.appendingPathComponent("EnduragentCoach_EnduragentCoach.bundle")))
		return try topics(
			in: try #require(
				coachBundle.url(
					forResource: "skills", withExtension: nil, subdirectory: "PromptResources")))
	}

	private func npmCopies() throws -> [String: String] {
		try topics(
			in: try #require(
				Bundle.module.url(
					forResource: "knowledge-topics-npm", withExtension: nil,
					subdirectory: "Fixtures")))
	}

	private func topics(in folder: URL) throws -> [String: String] {
		var topics: [String: String] = [:]
		for file in try FileManager.default.contentsOfDirectory(
			at: folder, includingPropertiesForKeys: nil)
		{
			topics["cycling-" + file.deletingPathExtension().lastPathComponent] =
				try String(contentsOf: file, encoding: .utf8)
		}
		return topics
	}

	private func npmRecord() throws -> [String: NpmTopic] {
		try JSONDecoder().decode(
			NpmRecord.self, from: try fixtureData("knowledge-topics-npm")
		).topics
	}

	private func sha256(_ text: String) -> String {
		SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
	}
}

private struct NpmRecord: Decodable {
	let topics: [String: NpmTopic]
}

private struct NpmTopic: Decodable {
	let npmSHA256: String
	let differences: [RecordedDifference]
}

private struct RecordedDifference: Decodable {
	let npm: String
	let phone: String
}
