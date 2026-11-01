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
			case "closeout":
				try phone.closeout(Array(arguments.dropFirst()))
			case "scan-diagnostics":
				try phone.scanDiagnostics(Array(arguments.dropFirst()))
			case "m4":
				try phone.m4(Array(arguments.dropFirst()))
			case "language":
				try phone.language(Array(arguments.dropFirst()))
			case "openrouter":
				try phone.openRouter(Array(arguments.dropFirst()))
			case "plan":
				try phone.plan(Array(arguments.dropFirst()))
			default:
				try Console.complain(
					"Usage: phone-check <choices|closeout|language|m4|openrouter|plan> [arguments]")
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

	func session(_ name: String) throws -> PhoneSessionPlan {
		try PhoneSessionPlan.load(path: PhoneSessionPlan.path(root: try root, name: name))
	}

	func sessions() throws -> [PhoneSessionPlan] {
		try ["m4", "plan", "closeout"].map(session)
	}

	func spent(_ plan: PhoneSessionPlan) throws -> Int {
		try readLedger(at: ledgerFile(of: plan), of: plan).spent
	}

	func ledgerFile(of plan: PhoneSessionPlan) -> String {
		NodePath.join(NSHomeDirectory(), "Library/Logs", plan.ledger)
	}

	func readLedger(at path: String, of plan: PhoneSessionPlan) throws -> PhoneLedger {
		try PhoneLedger(
			text: FileManager.default.fileExists(atPath: path)
				? String(decoding: try FileSystem.read(path), as: UTF8.self) : nil, plan: plan)
	}

	func book(_ ledger: PhoneLedger, at path: String) throws {
		try FileManager.default.createDirectory(
			atPath: NodePath.dirname(path), withIntermediateDirectories: true)
		try write(ledger.text, to: path)
	}

	func say(_ steps: [String], of plan: PhoneSessionPlan) throws {
		for step in plan.steps where steps.contains(step.id) {
			try Console.say("\(step.id) plans \(step.planned) message actions.")
			for setup in step.setup { try Console.say("  Setup: \(setup)") }
			for check in step.checks { try Console.say("  Check \(check.look): \(check.pass)") }
			try Console.say("  Ends with: \(step.endsWith)")
		}
	}

	func today() -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter.string(from: Date())
	}

	func verdict(after step: String) throws -> StepVerdict {
		let root = try root
		let day = today()
		while true {
			let answer = try ask("After \(step), type pass, fail <check> or blocked <reason>: ")
			do {
				let verdict = try SittingRecord.record(answer, for: step, on: day, root: root)
				try Console.say("Recorded \(step): \(verdict.text), in \(SittingRecord.path).")
				return verdict
			} catch let refusal as PhoneRefusal {
				try Console.complain(refusal.description)
			}
		}
	}

	func verdicts(_ steps: [String]) throws {
		for step in steps where try verdict(after: step) != .pass {
			throw PhoneFailure(
				description: "\(step) did not pass. Stop. A new invocation needs a new budget.")
		}
	}

	func run(_ commands: [[String]], with subprocess: Subprocess, logs: String) throws {
		for (index, command) in commands.enumerated() {
			try requireFreeDisk()
			let log = "\(logs)-\(index + 1).log"
			let end = try subprocess.logged(log, "caffeinate", ["-i"] + command, exclusive: true)
			guard end.succeeded else {
				throw PhoneFailure(description: "\(command[0]) failed. Stop and report \(log).")
			}
		}
	}

	func actions(of test: RunnerTest, in bundle: String, exportedTo folder: String) throws
		-> String?
	{
		do {
			try makeNewFolder(folder)
			try exportAttachments(
				of: bundle, to: folder, failure: "Cannot export the \(test.testClass) attachments.")
			let manifest = try JSONValue.parse(
				String(
					decoding: try FileSystem.read(NodePath.join(folder, "manifest.json")),
					as: UTF8.self))
			guard
				let file = try PlanPhoneBudget.actionsFile(
					in: manifest, named: test.actionsAttachment)
			else {
				try Console.complain(
					"The result bundle has no single \(test.actionsAttachment) log. Recording the whole budget as spent."
				)
				return nil
			}
			return String(decoding: try FileSystem.read(NodePath.join(folder, file)), as: UTF8.self)
		} catch {
			try Console.complain(
				"Cannot read the message actions: \(Console.text(of: error)). Recording the whole budget as spent."
			)
			return nil
		}
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
