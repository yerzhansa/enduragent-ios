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
					let deleted = try await seeder.unseed(
						retiringLedgerAs: "ledger-unseeded-\(stamp).tsv")
					report =
						"# Unseed \(stamp)\n\nDeleted \(deleted.count) activities: \(deleted.joined(separator: ", "))\n\nThe account lists no seeded activity.\n"
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
			return
				([
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
				] + rows).joined(separator: "\n") + "\n"
		}
	}
#endif
