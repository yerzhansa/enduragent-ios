import Foundation
import ToolSupport

struct PhoneSitting {
	let plan: PhoneSessionPlan
	let place: PhoneRunPlace
	let invocation: PhoneInvocation
	let subprocess: Subprocess
	let ledger: PhoneLedger
}

extension PhoneCheck {
	func place(device: String, folder: String, settings: [String: String] = [:])
		-> PhoneRunPlace
	{
		PhoneRunPlace(
			device: device, folder: folder, build: "/tmp/enduragent-dd/phone-check-tests",
			appBuild: "/tmp/enduragent-dd/phone-check-app", settings: settings)
	}

	func approve(_ steps: [String], of plan: PhoneSessionPlan, at place: PhoneRunPlace) throws
		-> PhoneSitting
	{
		let ledgerPath = ledgerFile(of: plan)
		let ledger = try readLedger(at: ledgerPath, of: plan)
		let planned = plan.planned(steps)
		try Console.say(
			"\(steps.joined(separator: ", ")) of the \(plan.name) phone session plan \(planned) message actions. Each Send, Try again and New conversation is one, and they spend the phone's Credits or its OpenRouter account. The \(plan.name) session has spent \(ledger.spent) of \(plan.cap)."
		)
		try say(steps, of: plan)
		let answer = try ask(
			"Approve this invocation's message budget, at least \(planned) and at most \(plan.cap - ledger.spent), acknowledging those charges. Enter a whole number or stop: "
		)
		let root = try root
		let started = try PhoneInvocationPlan.start(
			session: plan.name, answer: answer, steps: steps, sessions: try sessions(),
			ledgerSpent: spent, place: place, subprocess: { Subprocess(directory: root) })
		try makeNewFolder(place.folder)
		try write(
			JSONValue.keyed([
				"steps": .array(steps.map(JSONValue.string)),
				"plannedActions": .number(Double(planned)),
				"approvedBudget": .number(Double(started.invocation.budget)),
				"spentBefore": .number(Double(ledger.spent)), "chargesAcknowledged": .bool(true),
			]).indentedText, to: NodePath.join(place.folder, "approval.json"))
		try book(ledger.recording(started.invocation.row, actions: nil), at: ledgerPath)
		return PhoneSitting(
			plan: plan, place: place, invocation: started.invocation,
			subprocess: started.subprocess, ledger: ledger)
	}

	func walk(_ sitting: PhoneSitting, review: (PhoneStage) throws -> Void) throws {
		let walked = Result { try walkStages(sitting, review: review) }
		for build in [sitting.place.build, sitting.place.appBuild]
		where FileManager.default.fileExists(atPath: build) {
			try FileManager.default.removeItem(atPath: build)
		}
		try walked.get()
	}

	private func walkStages(_ sitting: PhoneSitting, review: (PhoneStage) throws -> Void) throws {
		var counted: [String] = []
		var read: [String] = []
		for stage in sitting.invocation.stages {
			switch stage.work {
			case .operatorTaps:
				try say(stage.steps, of: sitting.plan)
				try Console.say("Tap \(stage.steps.joined(separator: ", ")) on the phone now.")
			case .ownCommand(let command):
				try say(stage.steps, of: sitting.plan)
				try Console.say(
					"Run \(command) <device id> <new evidence folder> from this checkout for \(stage.steps.joined(separator: ", ")). It asks for its own budget inside the one booked here."
				)
			case .runs(let test, let bundle, let commands):
				let folder = NodePath.join(
					sitting.place.folder,
					stage.steps.joined(separator: "+").replacingOccurrences(of: "/", with: "-"))
				try makeNewFolder(folder)
				guard
					test.scheme == PhoneInvocationPlan.proofScheme
						|| !FileManager.default.fileExists(atPath: sitting.place.strayApp)
				else {
					throw PhoneFailure(
						description:
							"\(sitting.place.strayApp) exists and xcodebuild would install it over the installed build. Stop."
					)
				}
				let ran = Result {
					try run(commands, with: sitting.subprocess, logs: folder + "/run")
				}
				if stage.steps.contains(where: { sitting.plan.planned([$0]) > 0 }),
					let actions = try actions(
						of: test, in: bundle, exportedTo: NodePath.join(folder, "attachments"))
				{
					counted += stage.steps
					read.append(actions)
				}
				try recount(sitting, counted: counted, read: read)
				try ran.get()
				try keepPassingSummary(
					of: bundle, in: folder,
					unreadable: "Cannot read the \(test.testClass) result. Stop.",
					failed: "\(test.testClass) did not pass exactly once. Stop.")
			}
			try review(stage)
			try verdicts(stage.steps)
		}
	}

	private func recount(_ sitting: PhoneSitting, counted: [String], read: [String]) throws {
		let spending = sitting.invocation.steps.filter { sitting.plan.planned([$0]) > 0 }
		let onlyRunners = sitting.invocation.stages.allSatisfy { stage in
			guard case .runs = stage.work else { return false }
			return true
		}
		let actions =
			onlyRunners && spending.allSatisfy(counted.contains)
			? read.joined(separator: "\n") : nil
		let recorded = sitting.ledger.recording(sitting.invocation.row, actions: actions)
		try book(recorded, at: ledgerFile(of: sitting.plan))
		try Console.say(
			"This invocation has spent \(recorded.rows.last?.spent ?? sitting.invocation.budget) message actions. The \(sitting.plan.name) session has spent \(recorded.spent) of \(sitting.plan.cap)."
		)
	}
}
