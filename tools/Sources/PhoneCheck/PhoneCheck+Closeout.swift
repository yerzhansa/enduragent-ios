import Foundation
import ToolSupport

extension PhoneCheck {
	private static let diagnosticsStep = "closeout/diagnostics"
	private static let keychainProof = "closeout/keychain-proof"
	private static let twoPhone = "closeout/two-phone"
	private static let fixedMessageSteps = ["closeout/fill", "closeout/update"]
	private static let seedLedger = "Library/Logs/enduragent-m3/LIVE/seed/ledger.tsv"

	func closeout(_ arguments: [String]) throws {
		guard arguments.count == 4, !arguments[2].isEmpty, !arguments[3].isEmpty else {
			throw PhoneFailure(
				description:
					"Usage: phone-check closeout <first step> <last step> <device id> <new evidence folder>."
			)
		}
		guard hasOperatorTerminal else {
			throw PhoneFailure(
				description:
					"An operator terminal is required before approval, build, launch or Send.")
		}
		let plan = try session("closeout")
		let steps = try PhoneSteps(first: arguments[0], last: arguments[1], plan: plan)
		try Console.say(
			"These steps of the Milestone 6 closeout sitting run on the phone. phone-check runs the runner steps, prints the operator steps, and records each verdict in \(SittingRecord.path)."
		)
		let sitting = try approve(
			steps.ids, of: plan,
			at: place(
				device: arguments[2], folder: resolve(arguments[3]),
				settings: try proofSettings(for: steps.ids)))
		try walk(sitting) { stage in
			if stage.steps.contains(Self.diagnosticsStep) {
				try scanSavedDiagnostics(into: sitting.place.folder)
			}
		}
	}

	func scanDiagnostics(_ arguments: [String]) throws {
		guard arguments.count == 1, !arguments[0].isEmpty else {
			throw PhoneFailure(
				description: "Usage: with-intervals-key phone-check scan-diagnostics <file>.")
		}
		guard let key = ProcessInfo.processInfo.environment["INTERVALS_API_KEY"], !key.isEmpty
		else {
			throw PhoneFailure(description: "Run scan-diagnostics through with-intervals-key.")
		}
		let inputs = DiagnosticsScanInputs(
			athleteID: try seedAthlete(),
			intervalsKey: key,
			fixedMessages: try session("closeout").quotedMessages(of: Self.fixedMessageSteps))
		let problems = try DiagnosticsFileScan.problems(
			in: try FileSystem.read(resolve(arguments[0])), inputs: inputs)
		for problem in problems { try Console.complain(problem) }
		guard problems.isEmpty else {
			throw PhoneFailure(description: "The diagnostics file failed \(problems.count) checks.")
		}
		try Console.say("The diagnostics file passed the scan.")
	}

	private func proofSettings(for steps: [String]) throws -> [String: String] {
		var settings: [String: String] = [:]
		guard steps.contains(Self.keychainProof) || steps.contains(Self.twoPhone) else {
			return settings
		}
		settings["ENDURAGENT_DEVICE_UPDATE_CHECK"] = try ask(
			"Type the device-update check, starting with updated-together: and the checked build versions, without device identifiers: "
		)
		if steps.contains(Self.twoPhone) {
			settings["ENDURAGENT_OTHER_PHONE_BUILD"] = try ask(
				"Type the other device's installed proof-build version: ")
			settings["ENDURAGENT_RECONNECT_STEP"] = try ask(
				"Type this invocation's reconnect step from the verify-ios table: ")
		}
		return settings
	}

	private func scanSavedDiagnostics(into folder: String) throws {
		let saved = resolve(
			try ask("Type the path on this Mac of the diagnostics file the step saved: "))
		let copy = NodePath.join(folder, "diagnostics.json")
		try FileManager.default.copyItem(atPath: saved, toPath: copy)
		guard let executable = Bundle.main.executablePath else {
			throw PhoneFailure(description: "cannot find the running helper")
		}
		let end = try Subprocess().run(
			NodePath.join(NSHomeDirectory(), ".local/bin/with-intervals-key"),
			[executable, "scan-diagnostics", copy], output: .file(FileHandle.standardError))
		guard end.succeeded else {
			_ = try SittingRecord.record(
				"fail diagnostics-scan", for: Self.diagnosticsStep, on: today(), root: try root)
			throw PhoneFailure(
				description:
					"\(Self.diagnosticsStep) failed the diagnostics scan and is recorded as failed. Stop."
			)
		}
	}

	private func seedAthlete() throws -> String {
		let path = NodePath.join(NSHomeDirectory(), Self.seedLedger)
		let rows = String(decoding: try FileSystem.read(path), as: UTF8.self).split(separator: "\n")
		let athletes = rows.map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
			.filter { $0.count >= 2 && $0[0] == "athlete" && !$0[1].isEmpty }
		guard athletes.count == 1 else {
			throw PhoneFailure(
				description: "The live seed ledger does not name exactly one test athlete.")
		}
		return String(athletes[0][1])
	}
}
