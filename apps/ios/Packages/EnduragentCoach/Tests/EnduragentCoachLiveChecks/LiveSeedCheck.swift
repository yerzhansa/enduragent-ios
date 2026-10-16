#if os(macOS)
	import Foundation
	import Testing

	@testable import EnduragentCoach

	enum LiveSeedMode: String, Sendable {
		case seed
		case unseed

		static var selected: LiveSeedMode? {
			ProcessInfo.processInfo.environment[LiveCheck.selectorVariable].flatMap(
				LiveSeedMode.init(rawValue:))
		}
	}

	@Suite(.serialized) struct LiveSeedCheck {
		@Test(.enabled(if: LiveSeedMode.selected == .seed), .timeLimit(.minutes(30)))
		func seedsTheTestAccountWithSyntheticTraining() async throws {
			try await run(.seed)
		}

		@Test(.enabled(if: LiveSeedMode.selected == .unseed), .timeLimit(.minutes(10)))
		func removesEverythingTheSeedWrote() async throws {
			try await run(.unseed)
		}

		private func run(_ mode: LiveSeedMode) async throws {
			let started = Date()
			do {
				let key = try #require(
					try LiveKey.secrets([.intervals], lookUp: LiveKey.lookUpInKeychain)[.intervals])
				let folder = try Self.folder()
				let account = IntervalsSeedAccount(key: key)
				let stamp = LiveRunFolder.stamp(started)
				var seeder = LiveSeeder(
					account: account,
					today: IntervalsPolicy.today(now: started, timeZone: .current),
					polling: SeedPolling(
						attempts: 120, interval: .seconds(5),
						sleep: { try await Task.sleep(for: $0) }),
					ledger: try LiveSeedLedger(file: folder.appending(path: "ledger.tsv")))
				let report: String
				switch mode {
				case .seed:
					let athlete = try SeedAthlete(try await account.client.profile())
					let outcome = try await seeder.seed { activity in
						Data(
							try LiveSeedTCX.document(
								of: activity, athlete: athlete, timeZone: .current
							)
							.utf8)
					}
					report = Self.report(outcome, ledger: seeder.ledger, athlete: athlete)
				case .unseed:
					let outcome = try await seeder.unseed(
						retiringLedgerAs: "ledger-unseeded-\(stamp).tsv")
					report = Self.report(outcome, stamp: stamp)
				}
				try Data(report.utf8).write(
					to: folder.appending(path: "\(stamp)-\(mode.rawValue).md"), options: .atomic)
			} catch let stop as LiveCheckStop {
				Issue.record(Comment(rawValue: stop.description))
			}
		}

		private static func folder() throws -> URL {
			guard let logs = ProcessInfo.processInfo.environment[LiveCheck.logsVariable],
				!logs.isEmpty
			else {
				throw LiveCheckStop(
					description:
						"\(LiveCheck.logsVariable) is not set. Run make live-seed or make live-unseed."
				)
			}
			let folder = URL(fileURLWithPath: logs, isDirectory: true).appending(path: "seed")
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			return folder
		}

		private static func report(_ outcome: UnseedOutcome, stamp: String) -> String {
			let cleared = outcome.cleared.sorted { $0.key < $1.key }.map { date, fields in
				"\(date.rawValue) \(fields.joined(separator: ","))"
			}
			let changed =
				outcome.changedSinceSeed.isEmpty
				? "none" : outcome.changedSinceSeed.joined(separator: ", ")
			return [
				"# Unseed \(stamp)", "",
				"- Deleted \(outcome.deleted.count) activities: \(outcome.deleted.joined(separator: ", "))",
				"- Skipped \(outcome.skipped.count) ledger activities the account no longer lists as seeded: \(outcome.skipped.isEmpty ? "none" : outcome.skipped.joined(separator: "; "))",
				"- Cleared wellness on \(cleared.count) days, read back as empty: \(cleared.joined(separator: "; "))",
				"- Left because the value changed since the seed wrote it: \(changed)",
				"- Removed \(outcome.calendarRemoved.count) calendar entries: \(outcome.calendarRemoved.keys.sorted().joined(separator: ", "))",
				"",
				"The account lists no seeded activity and no calendar entry of the ledger.", "",
			].joined(separator: "\n")
		}

		private static func calendarRow(_ event: CalendarEvent) -> String {
			let cells: [String] = [
				String(event.startDateLocal.prefix(10)), String(event.id.rawValue),
				event.externalId ?? "", event.category, event.name ?? "no name",
				LiveCalendarRun.text(event.movingTime), LiveCalendarRun.text(event.trainingLoad),
			]
			return "| " + cells.joined(separator: " | ") + " |"
		}

		private static func report(
			_ outcome: SeedOutcome, ledger: LiveSeedLedger, athlete: SeedAthlete
		)
			-> String
		{
			let rows = outcome.listed.sorted { ($0.start ?? "") < ($1.start ?? "") }.map { row in
				let load = row.load.map { String(Int($0)) } ?? "none"
				let feel = row.feel.map(String.init) ?? "-"
				let rpe = row.rpe.map(String.init) ?? "-"
				return
					"| \(row.start ?? "") | \(row.id) | \(row.externalID ?? "") | \(row.name ?? "") | \(load) | \(feel) | \(rpe) |"
			}
			let calendar: [String] = outcome.calendarListed.sorted {
				$0.startDateLocal < $1.startDateLocal
			}.map(calendarRow)
			let head: [String] = [
				"# Seed", "",
				"Scaled to FTP \(Int(athlete.ftp)) W, LTHR \(Int(athlete.lthr)) bpm, max HR \(Int(athlete.maxHeartRate)) bpm.",
				"",
				"- Ledger: \(ledger.summary)",
				"- Uploaded: \(outcome.uploaded.count); already there: \(outcome.kept.count)",
				"- Feel and RPE set: \(outcome.rated.count)",
				"- Wellness days written: \(outcome.wellnessWritten.count); already there: \(outcome.wellnessKept)",
				"",
				"| Start | Id | External id | Name | Load | Feel | RPE |",
				"| --- | --- | --- | --- | --- | --- | --- |",
			]
			let calendarHead: [String] = [
				"",
				"- Calendar entries added: \(outcome.calendarAdded.count); already there: \(outcome.calendarKept.count)",
				"",
				"| Date | Id | External id | Category | Name | Duration | Load |",
				"| --- | --- | --- | --- | --- | --- | --- |",
			]
			return (head + rows + calendarHead + calendar).joined(separator: "\n") + "\n"
		}
	}
#endif
