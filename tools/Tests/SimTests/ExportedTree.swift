import Foundation
import ToolSupport

private final class BuiltProducts {}

struct HelperOverdue: Error {
	let command: String
}

struct HelperResult {
	let status: Int32?
	let output: String
	let errors: String

	static func of(
		_ executable: String, _ arguments: [String], directory: String,
		environment: [String: String], scratch: String
	) throws -> HelperResult {
		let files = FileManager.default
		let run = UUID().uuidString
		let printed = "\(scratch)/printed-\(run)"
		let complained = "\(scratch)/complained-\(run)"
		for file in [printed, complained] {
			guard files.createFile(atPath: file, contents: nil) else {
				throw FileFailure(code: EIO, path: file)
			}
		}
		let process = Process()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments
		process.currentDirectoryURL = URL(fileURLWithPath: directory)
		process.environment = environment
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: printed))
		process.standardError = try FileHandle(forWritingTo: URL(fileURLWithPath: complained))
		try process.run()
		let deadline = Date().addingTimeInterval(90)
		while process.isRunning, Date() < deadline {
			Thread.sleep(forTimeInterval: 0.02)
		}
		guard !process.isRunning else {
			process.terminate()
			throw HelperOverdue(command: ([executable] + arguments).joined(separator: " "))
		}
		let result = HelperResult(
			status: Subprocess.end(of: process).status,
			output: String(decoding: try FileSystem.read(printed), as: UTF8.self),
			errors: String(decoding: try FileSystem.read(complained), as: UTF8.self))
		try files.removeItem(atPath: printed)
		try files.removeItem(atPath: complained)
		return result
	}
}

struct ExportedTree {
	static let helperFolders = ["tools/.build/debug", "tools/.build/arm64-apple-macosx/debug"]

	let root: String
	let tree: String
	let build: String
	let runs: String
	let recordings: String
	let devices: String

	static var products: String {
		Bundle(for: BuiltProducts.self).bundleURL.deletingLastPathComponent().path
	}

	init() throws {
		let files = FileManager.default
		root =
			try FileSystem.realPath(files.temporaryDirectory.path)
			+ "/enduragent-verify-test-\(UUID().uuidString)"
		tree = "\(root)/export"
		build = "\(root)/build"
		runs = "\(root)/runs"
		recordings = "\(root)/recordings"
		devices = "\(root)/devices"
		let helpers = "\(tree)/\(Self.helperFolders[1])"
		try files.createDirectory(atPath: helpers, withIntermediateDirectories: true)
		try files.copyItem(atPath: "\(Self.products)/sim", toPath: "\(helpers)/sim")
		try files.createSymbolicLink(
			atPath: "\(tree)/\(Self.helperFolders[0])",
			withDestinationPath: "arm64-apple-macosx/debug")
		let source = "\(tree)/apps/ios/EnduragentUITests"
		try files.createDirectory(atPath: source, withIntermediateDirectories: true)
		let classes = ["AlphaProof", "BravoProof", "CharlieProof"].map {
			"final class \($0): XCTestCase {}"
		}
		try write(
			"\(classes.joined(separator: "\n"))\nfinal class TimingProbe: XCTestCase {}\nfinal class FrenchSweep: XCTestCase {}\n",
			to: "\(source)/Proofs.swift")
		try files.createDirectory(atPath: "\(root)/bin", withIntermediateDirectories: false)
		for tool in ["git", "xcrun", "xcodegen", "xcodebuild", "plutil", "sips"] {
			try files.createSymbolicLink(
				atPath: "\(root)/bin/\(tool)",
				withDestinationPath: "\(Self.products)/SimFixtureTool")
		}
	}

	func remove() throws {
		try FileManager.default.removeItem(atPath: root)
	}

	func write(_ text: String, to path: String) throws {
		try Data(text.utf8).write(to: URL(fileURLWithPath: path))
	}

	func read(_ path: String) throws -> String {
		String(decoding: try FileSystem.read(path), as: UTF8.self)
	}

	func names(in folder: String) throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
	}

	func exists(_ path: String) -> Bool {
		FileManager.default.fileExists(atPath: path)
	}

	func sim(
		_ arguments: [String], environment: [String: String] = [:],
		through helperFolder: String = ExportedTree.helperFolders[0]
	) throws -> HelperResult {
		try run("\(tree)/\(helperFolder)/sim", arguments, environment: environment)
	}

	func fakeTool(_ name: String, _ arguments: [String], environment: [String: String] = [:]) throws
		-> HelperResult
	{
		try run("\(root)/bin/\(name)", arguments, environment: environment)
	}

	func calls() throws -> [(command: String, arguments: [String])] {
		try names(in: root).filter { $0.hasPrefix("call-") }.map { name in
			let call = try JSONValue.parse(read("\(root)/\(name)"))
			return (
				try call.member("command").interpolated,
				try call.member("args").elements().map(\.interpolated)
			)
		}
	}

	private func run(_ executable: String, _ arguments: [String], environment: [String: String])
		throws
		-> HelperResult
	{
		var complete = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("VERIFY_") }
		complete["PATH"] = "\(root)/bin"
		complete["ENDURAGENT_VERIFY_FAKE_ROOT"] = root
		complete["ENDURAGENT_VERIFY_RUNS"] = runs
		complete["ENDURAGENT_VERIFY_RECORDINGS"] = recordings
		complete["ENDURAGENT_VERIFY_BUILD"] = build
		complete["ENDURAGENT_VERIFY_REVISION"] = nil
		complete.merge(environment) { $1 }
		return try HelperResult.of(
			executable, arguments, directory: root, environment: complete, scratch: root)
	}
}
