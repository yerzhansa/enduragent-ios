import Foundation
import Testing
import ToolSupport

@testable import CheckSource

struct SourceCheckerTests {
	@Test(.timeLimit(.minutes(1)), arguments: SourceCases.all)
	func givesTheVerdictForATrackedTree(_ sourceCase: SourceCase) throws {
		for scratch in sourceCase.runs {
			let result = try scratch.check()
			#expect(result.status == scratch.status, "\(result.output)")
			for finding in scratch.findings {
				#expect(result.output.contains(finding), "\(result.output)")
			}
			for hidden in scratch.hidden {
				#expect(!result.output.contains(hidden))
			}
			if let output = scratch.output {
				#expect(result.output == output)
			}
			if let lines = scratch.findingLines {
				#expect(
					result.output.split(separator: "\n").filter { $0.contains("[") }.map(
						String.init) == lines)
			}
		}
	}
}

enum SourceCases {
	static let all: [SourceCase] =
		links + xcodeSettings + navigationStacks + fixtureFolders + hangGuards + waitDeadlines
		+ proofHelpers + binaries + ledgerIndexes + contentRules + mailboxState + featureProofs
		+ fixtureLaunch + recordAccess + secretStores + port
}

enum Link: Sendable {
	case relative(String)
	case insideRepository(String)
}

enum Tracked: Sendable {
	case everything
	case nothing
	case only([String])
}

struct Scratch: Sendable {
	var files: [String: String] = [:]
	var binaries: [String: [UInt8]] = [:]
	var links: [String: Link] = [:]
	var tracked = Tracked.everything
	var status: Int32 = 0
	var findings: [String] = []
	var hidden: [String] = []
	var findingLines: [String]?
	var output: String?

	func check() throws -> (status: Int32, output: String) {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ios-source-check-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let outcome = Result { try check(in: root) }
		try FileManager.default.removeItem(at: root)
		return try outcome.get()
	}

	private func check(in root: URL) throws -> (status: Int32, output: String) {
		_ = try Tool.output("git", ["init", "-q", root.path])
		let contents =
			files.mapValues { Data($0.utf8) }.merging(binaries.mapValues { Data($0) }) { $1 }
		for (file, content) in contents {
			try content.write(to: try parent(of: file, in: root))
		}
		for (file, link) in links {
			let target =
				switch link {
				case .relative(let path): path
				case .insideRepository(let path): root.appendingPathComponent(path).path
				}
			try FileManager.default.createSymbolicLink(
				atPath: try parent(of: file, in: root).path, withDestinationPath: target)
		}
		switch tracked {
		case .everything:
			_ = try Tool.output("git", ["-C", root.path, "add", "-f", "--", "."])
		case .only(let paths):
			_ = try Tool.output("git", ["-C", root.path, "add", "-f", "--"] + paths)
		case .nothing:
			break
		}
		let output = Lines()
		let errors = Lines()
		let status = try CheckSource.run(
			arguments: ["--root", root.path], directory: root.path,
			output: { output.lines.append($0) }, errors: { errors.lines.append($0) })
		return (status, (output.lines + errors.lines).map { "\($0)\n" }.joined())
	}

	private func parent(of file: String, in root: URL) throws -> URL {
		let url = root.appendingPathComponent(file)
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		return url
	}
}

private final class Lines {
	var lines: [String] = []
}

struct SourceCase: Sendable, CustomTestStringConvertible {
	let name: String
	let runs: [Scratch]

	var testDescription: String { name.quotedAsJSON }

	static func accepts(
		_ name: String, _ files: [String: String] = [:], binaries: [String: [UInt8]] = [:],
		links: [String: Link] = [:], tracked: Tracked = .everything
	) -> SourceCase {
		SourceCase(
			name: name,
			runs: [Scratch(files: files, binaries: binaries, links: links, tracked: tracked)])
	}

	static func rejects(
		_ name: String, _ files: [String: String] = [:], binaries: [String: [UInt8]] = [:],
		links: [String: Link] = [:], tracked: Tracked = .everything, finding: String,
		hidden: [String] = [], findingLines: [String]? = nil
	) -> SourceCase {
		SourceCase(
			name: name,
			runs: [
				Scratch(
					files: files, binaries: binaries, links: links, tracked: tracked, status: 1,
					findings: [finding], hidden: hidden, findingLines: findingLines)
			])
	}
}
