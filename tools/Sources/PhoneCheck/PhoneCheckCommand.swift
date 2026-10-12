import Foundation
import ToolSupport

struct PhoneFailure: DescribedFailure {
	let description: String
}

@main
struct PhoneCheckCommand {
	static func main() throws {
		let arguments = Array(CommandLine.arguments.dropFirst())
		do {
			let phone = PhoneCheck()
			switch arguments.first {
			case "choices":
				try phone.choices(Array(arguments.dropFirst()))
			case "language":
				try phone.language(Array(arguments.dropFirst()))
			case "openrouter":
				try phone.openRouter(Array(arguments.dropFirst()))
			default:
				try Console.complain("Usage: phone-check <choices|language|openrouter> [arguments]")
				exit(2)
			}
		} catch {
			try Console.complain("phone-check: \(Console.text(of: error))")
			exit(1)
		}
	}
}

struct PhoneCheck {
	let patterns = JavaScriptPatterns()

	var root: String {
		get throws {
			guard let executable = Bundle.main.executablePath else {
				throw PhoneFailure(description: "cannot find the running helper")
			}
			return try Checkout.root(ofExecutable: executable)
		}
	}

	var hasOperatorTerminal: Bool { isatty(STDIN_FILENO) == 1 }

	func ask(_ question: String) throws -> String {
		try FileHandle.standardOutput.write(contentsOf: Data(question.utf8))
		guard let answer = readLine(strippingNewline: true) else {
			throw PhoneFailure(description: "The operator terminal closed. Stop.")
		}
		return answer
	}

	func resolve(_ path: String) -> String {
		NodePath.resolve(FileManager.default.currentDirectoryPath, path)
	}

	func makeNewFolder(_ path: String) throws {
		try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
	}

	func write(_ text: String, to path: String) throws {
		try Data(text.utf8).write(to: URL(fileURLWithPath: path))
	}

	func requireFreeDisk() throws {
		let disk = try Subprocess().collect("df", ["-k", "/System/Volumes/Data"])
		guard disk.end.succeeded else {
			throw PhoneFailure(description: "Cannot check free disk space.")
		}
		let lines = String(decoding: disk.output, as: UTF8.self).trimmedAsJavaScript.split(
			separator: "\n", omittingEmptySubsequences: false)
		let fields = try patterns.split(#"\s+"#, String(lines.last ?? "").trimmedAsJavaScript)
		let available = fields.count > 3 ? JavaScriptNumber.parse(fields[3]) : .nan
		guard available.isFinite, available >= 3 * 1024 * 1024 else {
			throw PhoneFailure(description: "The disk has less than 3 GB free. Stop.")
		}
	}

	func xcodebuild(_ arguments: [String], log: String, failure: String) throws {
		let end = try Subprocess(directory: try root).logged(
			log, "caffeinate", ["-i", "xcodebuild"] + arguments, exclusive: true)
		guard end.succeeded else { throw PhoneFailure(description: failure) }
	}

	func keepPassingSummary(
		of bundle: String, in folder: String, unreadable: String, failed: String
	)
		throws
	{
		let summary = try Subprocess().collect(
			"xcrun",
			["xcresulttool", "get", "test-results", "summary", "--path", bundle, "--compact"])
		guard summary.end.succeeded else { throw PhoneFailure(description: unreadable) }
		let text = String(decoding: summary.output, as: UTF8.self)
		try write(text, to: NodePath.join(folder, "summary.json"))
		let counts = try JSONValue.parse(text)
		let expected: KeyValuePairs<String, Double> = [
			"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0,
			"expectedFailures": 0,
		]
		for (key, value) in expected where try counts.member(key).number != value {
			throw PhoneFailure(description: failed)
		}
	}

	func exportAttachments(of bundle: String, to folder: String, failure: String) throws {
		let exported = try Subprocess().collect(
			"xcrun",
			["xcresulttool", "export", "attachments", "--path", bundle, "--output-path", folder])
		guard exported.end.succeeded else { throw PhoneFailure(description: failure) }
	}
}
