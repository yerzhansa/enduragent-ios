import Foundation

@testable import EnduragentCoach

struct LiveCalendarRun {
	let account: any SeedAccount
	let plan: LiveCalendarPlan
	let rewrites: IntervalsRewrites
	var ledger: LiveSeedLedger
	let sendRefused: @Sendable (CalendarWrite) async -> IntervalsWriteAnswer
	let dropNextAnswer: @Sendable () -> Void
	let drain: @Sendable () -> [TappedResponse]
	var failures: [String] = []
	private(set) var log: [String] = []
	private(set) var responses: [(step: String, response: TappedResponse)] = []
	private var step = "start"

	init(
		account: any SeedAccount, plan: LiveCalendarPlan, rewrites: IntervalsRewrites,
		ledger: LiveSeedLedger,
		sendRefused: @escaping @Sendable (CalendarWrite) async -> IntervalsWriteAnswer,
		dropNextAnswer: @escaping @Sendable () -> Void,
		drain: @escaping @Sendable () -> [TappedResponse]
	) {
		self.account = account
		self.plan = plan
		self.rewrites = rewrites
		self.ledger = ledger
		self.sendRefused = sendRefused
		self.dropNextAnswer = dropNextAnswer
		self.drain = drain
	}

	var client: any IntervalsClient { account.calendar }

	static func ledgerFile() throws -> URL {
		guard let logs = ProcessInfo.processInfo.environment[LiveCheck.logsVariable],
			!logs.isEmpty
		else {
			throw LiveCheckStop(
				description: "\(LiveCheck.logsVariable) is not set. Run make live-calendar.")
		}
		return URL(fileURLWithPath: logs, isDirectory: true).appending(path: "seed/ledger.tsv")
	}

	mutating func run() async {
		guard await confirmAthlete() else { return }
		await readSeededEntries()
		let ride = await addAndReadBack(plan.ride)
		await resend(plan.ride, first: ride)
		let strength = await addAndReadBack(plan.strength)
		await editEachField()
		await moveAndResend(plan.movedNear)
		await moveAndResend(plan.movedFar)
		await refuseUnknownCategory()
		await deleteTwice(strength)
		await loseEachAnswer()
		await reviewThroughTheDesk()
		await removeEverything()
	}

	private mutating func confirmAthlete() async -> Bool {
		begin("athlete guard")
		guard let recorded = ledger.athlete else {
			fail(
				"Nothing was written: the seed ledger names no athlete. Run make live-seed first.")
			return false
		}
		let athlete: String
		do {
			athlete = try await account.athleteID()
		} catch {
			fail(
				"Nothing was written: the profile read failed (\(LiveCalendarSweep.describe(error)))."
			)
			return false
		}
		guard athlete == recorded else {
			fail(
				"Nothing was written: the seed ledger belongs to athlete \(recorded), but the key belongs to athlete \(athlete)."
			)
			return false
		}
		note("The key's athlete is the seed ledger's athlete.")
		return true
	}

	private mutating func readSeededEntries() async {
		begin("seeded entries")
		let listed: [CalendarEvent]
		do {
			listed = try await client.listEvents(
				in: try LiveSeedCalendar.window(around: plan.today))
		} catch {
			fail("the window read failed: \(LiveCalendarSweep.describe(error))")
			return
		}
		for entry in LiveSeedCalendar.entries {
			let rows = listed.filter { $0.externalId == entry.externalID }
			guard rows.count == 1, let event = rows.first else {
				fail("\(entry.key) lists \(rows.count) times, not once. Run make live-seed.")
				continue
			}
			note(
				"\(entry.key): \(event.category), \(event.name.map { "\"\($0)\"" } ?? "no name"), duration \(Self.text(event.movingTime)), Load \(Self.text(event.trainingLoad)), on \(event.startDateLocal.prefix(10))"
			)
			let diffs = [
				Self.diff("category", .string(entry.category), .string(event.category)),
				Self.diff("name", .string(entry.name), Self.json(event.name)),
				Self.diff("moving_time", Self.json(entry.seconds), Self.json(event.movingTime)),
				Self.diff(
					"icu_training_load", Self.json(entry.load), Self.json(event.trainingLoad)),
			].compactMap { $0 }
			report(
				diffs, of: entry.key,
				in: LiveSave(sentDescription: true, sentStructure: false, stored: event))
		}
	}

	private mutating func addAndReadBack(_ add: LiveCalendarAdd) async -> EventID? {
		begin("add \(add.key)")
		guard let saved = await send(add) else { return nil }
		do {
			let stored = try await client.fetchEvent(id: saved.id)
			let save = LiveSave(sentDescription: true, sentStructure: false, stored: stored)
			report(Self.diffs(sent: add, stored: stored), of: add.key, in: save)
			checkParsedSteps(of: add, in: save)
		} catch {
			fail(
				"the read back of event \(saved.id.rawValue) failed: \(LiveCalendarSweep.describe(error))"
			)
		}
		return saved.id
	}

	private mutating func resend(_ add: LiveCalendarAdd, first: EventID?) async {
		begin("resend \(add.key)")
		guard let first else {
			fail("not run, because the first send saved no event")
			return
		}
		guard let again = await send(add) else { return }
		if again.id != first {
			fail("the second send answered event \(again.id.rawValue), the first \(first.rawValue)")
		}
		if again.externalId != add.externalID {
			fail("the second answer carries \(again.externalId ?? "no external_id")")
		}
		await expectOne(add, in: add.payload.date, id: first)
	}

	private mutating func editEachField() async {
		begin("edit")
		guard let id = await send(plan.edited)?.id else { return }
		for (field, patch) in plan.edits {
			begin("edit \(field)")
			do {
				let before = try await client.fetchEvent(id: id)
				let answer = await client.write(.update(id, patch))
				note("PUT \(field) answered \(Self.text(answer))")
				guard case .saved = answer else {
					fail("the edit of \(field) answered \(Self.text(answer))")
					continue
				}
				let after = try await client.fetchEvent(id: id)
				let expected = patch.applied(to: try before.snapshot)
				let stored = try after.snapshot
				report(
					Self.diffs(expected: expected, stored: stored), of: "edit of \(field)",
					in: LiveSave(
						sentDescription: patch.description != nil,
						sentStructure: patch.workoutDocument != nil, stored: after))
				if after.externalId != plan.edited.externalID {
					fail(
						"the edit of \(field) left external_id \(after.externalId ?? "none")")
				}
				if patch.applied(to: stored) != stored {
					fail("applying the edit of \(field) to its read back changes it")
				}
			} catch {
				fail("the edit of \(field) failed: \(LiveCalendarSweep.describe(error))")
			}
		}
	}

	private mutating func moveAndResend(_ move: LiveCalendarMove) async {
		let add = move.add
		begin("move \(add.key)")
		guard let first = await send(add)?.id else { return }
		let answer = await client.write(.update(first, move.patch))
		guard case .saved = answer else {
			fail("the move by \(move.days) days answered \(Self.text(answer))")
			return
		}
		do {
			let inWindow = try await client.listEvents(
				in: try LiveSeedCalendar.window(around: add.payload.date)
			).filter { $0.externalId == add.externalID }
			let found = inWindow.map { "\($0.id.rawValue) on \($0.startDateLocal.prefix(10))" }
			note(
				"Moved \(move.days) days to \(move.destination.rawValue); the add's window \(try move.staysInWindow ? "holds" : "does not hold") that day and lists \(found.isEmpty ? "nothing" : found.joined(separator: ", "))."
			)
			if try move.staysInWindow,
				inWindow.map(\.id) != [first]
					|| inWindow.first?.startDateLocal.hasPrefix(move.destination.rawValue) != true
			{
				fail(
					"the window read did not find event \(first.rawValue) on \(move.destination.rawValue)"
				)
			}
		} catch {
			fail("the window read failed: \(LiveCalendarSweep.describe(error))")
		}
		begin("resend \(add.key)")
		guard let again = await send(add) else { return }
		if again.id != first {
			fail("the resend answered event \(again.id.rawValue), the first \(first.rawValue)")
		}
		note("The resend left the event on \(again.startDateLocal.prefix(10)).")
		await expectOne(add, in: move.destination, id: first)
	}

	private mutating func refuseUnknownCategory() async {
		let add = plan.refused
		begin("refused \(add.key)")
		guard record(add) else { return }
		let answer = await sendRefused(add.write)
		let tapped = drained()
		for response in tapped {
			note("\(response.request) answered HTTP \(response.status): \(response.excerpt)")
		}
		note(
			"write(_:) answered \(Self.text(answer)) to category \(LiveCalendarPlan.unknownCategory)"
		)
		switch answer {
		case .saved:
			fail("an add with an unknown category was saved")
		case .httpStatus, .lost:
			break
		}
		await expectNone(add)
	}

	private mutating func deleteTwice(_ id: EventID?) async {
		begin("delete")
		guard let id else {
			fail("not run, because the strength session saved no event")
			return
		}
		let first = await client.write(.delete(id))
		let second = await client.write(.delete(id))
		let put = await client.write(.update(id, plan.edits[1].patch))
		note(
			"DELETE answered \(Self.text(first)); a second DELETE \(Self.text(second)); a PUT \(Self.text(put))"
		)
		if first != .saved(nil) { fail("the DELETE answered \(Self.text(first))") }
		if second != .httpStatus(404) { fail("the second DELETE answered \(Self.text(second))") }
		if put != .httpStatus(404) { fail("the PUT to a deleted event answered \(Self.text(put))") }
		do {
			let event = try await client.fetchEvent(id: id)
			fail("a GET of the deleted event answered event \(event.id.rawValue)")
		} catch let error as IntervalsError where error.status == 404 {
			note("A GET of it answered 404.")
		} catch {
			fail("a GET of the deleted event failed: \(LiveCalendarSweep.describe(error))")
		}
	}

	private mutating func removeEverything() async {
		begin("remove")
		let mine = plan.adds.map(\.externalID).filter { ledger.calendar[$0] != nil }
		let outcome = await LiveCalendarSweep.remove(mine, ledger: &ledger, client: client)
		for (externalID, ids) in outcome.removed.sorted(by: { $0.key < $1.key }) {
			note(
				"Removed \(externalID): \(ids.isEmpty ? "already gone" : ids.map { String($0.rawValue) }.joined(separator: ", "))"
			)
		}
		for left in outcome.left {
			fail("left on the calendar: \(left)")
		}
	}

	mutating func send(_ add: LiveCalendarAdd) async -> CalendarEvent? {
		guard record(add) else { return nil }
		let answer = await client.write(add.write)
		note("POST bulk \(add.key) answered \(Self.text(answer))")
		guard case .saved(let event?) = answer else {
			fail("the add of \(add.key) answered \(Self.text(answer))")
			return nil
		}
		if event.externalId != add.externalID {
			fail("the add of \(add.key) answered external_id \(event.externalId ?? "none")")
		}
		do {
			try ledger.record(calendar: add.externalID, event: event.id)
		} catch {
			fail(
				"the ledger did not record event \(event.id.rawValue): \(LiveCalendarSweep.describe(error))"
			)
		}
		return event
	}

	mutating func record(_ add: LiveCalendarAdd) -> Bool {
		guard ledger.calendar[add.externalID] == nil else { return true }
		do {
			try ledger.record(calendar: add.externalID, on: add.payload.date)
			return true
		} catch {
			fail(
				"nothing was sent, because the ledger did not record \(add.externalID): \(LiveCalendarSweep.describe(error))"
			)
			return false
		}
	}

	private mutating func expectOne(_ add: LiveCalendarAdd, in other: CivilDate, id: EventID) async
	{
		do {
			var found: [EventID: CalendarEvent] = [:]
			for date in Set([add.payload.date, other]) {
				for event in try await client.listEvents(
					in: try LiveSeedCalendar.window(around: date))
				where event.externalId == add.externalID {
					found[event.id] = event
				}
			}
			note(
				"Events carrying \(add.key)'s external_id: \(found.values.map { "\($0.id.rawValue) on \($0.startDateLocal.prefix(10))" }.sorted().joined(separator: ", "))"
			)
			if Array(found.keys) != [id] {
				fail(
					"\(found.count) events carry \(add.key)'s external_id, not event \(id.rawValue) alone"
				)
			}
		} catch {
			fail("the window read failed: \(LiveCalendarSweep.describe(error))")
		}
	}

	private mutating func expectNone(_ add: LiveCalendarAdd) async {
		do {
			let found = try await client.listEvents(
				in: try LiveSeedCalendar.window(around: add.payload.date)
			).filter { $0.externalId == add.externalID }
			note("Events carrying \(add.key)'s external_id: \(found.count)")
			if !found.isEmpty {
				fail(
					"the refused add left events \(found.map { String($0.id.rawValue) }.joined(separator: ", "))"
				)
			}
		} catch {
			fail("the window read failed: \(LiveCalendarSweep.describe(error))")
		}
	}

	mutating func report(_ diffs: [LiveFieldDiff], of subject: String, in save: LiveSave) {
		for diff in diffs {
			note("\(subject): intervals.icu stored \(diff.line)")
		}
		for diff in rewrites.unlisted(diffs, in: save) {
			fail("\(subject): \(diff.line), a rewrite intervals-rewrites.json does not list")
		}
	}

	mutating func begin(_ name: String) {
		collect()
		step = name
		log.append("")
		log.append("## \(name)")
	}

	mutating func note(_ line: String) {
		log.append("- \(line)")
	}

	mutating func fail(_ line: String) {
		failures.append("\(step): \(line)")
		log.append("- FAILED: \(line)")
	}

	mutating func drained() -> [TappedResponse] {
		let tapped = drain()
		responses += tapped.map { (step, $0) }
		return tapped
	}

	mutating func collect() {
		responses += drain().map { (step, $0) }
	}
}
