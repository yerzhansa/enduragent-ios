extension SourceCases {
	static let coachTests = "apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests"
	static let coachFixtures = "apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoachFixtures"
	static let appFixtureTests = "apps/ios/EnduragentTests/FixtureTests.swift"
	static let appFixtureScope = "apps/ios/EnduragentTests/FixtureTestScope.swift"
	static let folderOwnership = "app-fixture-folder-ownership"

	static let fixtureFolders: [SourceCase] =
		[
			.rejects(
				"rejects app tests deleting fixture folders outside their async owner",
				[appFixtureTests: "deinit { try FileManager.default.removeItem(at: directory) }"],
				finding: folderOwnership),
			.accepts(
				"accepts app tests awaiting fixture folder cleanup",
				[appFixtureTests: "try await folder.cleanup { await owners.release() }"]),
		]
		+ [
			"let directory = FileManager.default.temporaryDirectory",
			"let directory = NSTemporaryDirectory()",
			"try AppServices.fixture(launch, defaults: defaults)",
		].map { value in
			.rejects(
				"rejects app tests bypassing the shared fixture owner: \(value)",
				[appFixtureTests: value], finding: folderOwnership)
		}
		+ [
			.accepts(
				"accepts the shared app fixture owner creating folders and services",
				[
					appFixtureScope:
						"let directory = try TestTemporaryFolders.make()\n"
						+ "try AppServices.fixture(launch, defaults: defaults)"
				])
		]
		+ [
			"Packages/EnduragentCoach/Tests/EnduragentCoachTests", "EnduragentTests",
			"EnduragentUITests", "EnduragentPhoneTests",
		].flatMap { target in
			[
				"FileManager.default.temporaryDirectory", "NSTemporaryDirectory()",
				#""/tmp/shared-output""#,
			].map { value in
				SourceCase.rejects(
					"rejects tests bypassing the shared temporary folder owner in \(target): \(value)",
					["apps/ios/\(target)/FolderTests.swift": "let directory = \(value)"],
					finding: folderOwnership)
			}
		}
		+ ["FileManager.default.temporaryDirectory", "NSTemporaryDirectory()"].map { value in
			.rejects(
				"rejects the app fixture scope bypassing shared temporary folder allocation: \(value)",
				[appFixtureScope: "let directory = \(value)"], finding: folderOwnership)
		}
		+ [
			.accepts(
				"accepts the shared temporary folder helper",
				[
					"\(coachFixtures)/TestTemporaryFolders.swift":
						"let directory = FileManager.default.temporaryDirectory"
				])
		]

	static let testWaitFiles = [
		"\(coachTests)/WaitSupport.swift", "\(coachFixtures)/WaitSupport.swift",
		"apps/ios/EnduragentTests/WaitSupport.swift",
	]
	static let literalHangGuards = [
		"try await beforeDeadline(within: .seconds(5)) { await event() }",
		"try await beforeDeadline(\nwithin: Duration.milliseconds(20)) { await event() }",
		"let clock = HeldClock(within: .zero)",
		"func wait(within limit: Duration = .seconds(5)) {}",
		"let deadline = ContinuousClock.now + .seconds(5)",
		"let deadline = ContinuousClock().now + Duration.seconds(5)",
		"group.addTask { try await Task.sleep(for: .seconds(10)); return false }",
		"group.addTask {\ntry await Task.sleep(for: Duration.seconds(5))\nreturn nil\n}",
	]
	static let namedHangGuards = """
		      try await beforeDeadline(within: .hangGuard) { await event() }
		      try await beforeDeadline(within: .subject(.milliseconds(20))) { await event() }
		      let clock = HeldClock(within: .subject(.zero))
		      func wait(within limit: TestWaitLimit = .hangGuard) {}
		      let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		      let observation = ContinuousClock.now + TestWaitLimit.subject(.seconds(1)).duration
		      group.addTask { try await Task.sleep(for: TestWaitLimit.hangGuard.duration); return false }
		      group.addTask { try await Task.sleep(for: TestWaitLimit.subject(.milliseconds(20)).duration); return nil }
		      clock.advance(by: .seconds(7))
		      try await clock.sleep(for: .seconds(11))
		      try await Task.sleep(for: .milliseconds(10))
		      let text = "beforeDeadline(within: .seconds(5))"
		"""

	static let hangGuards: [SourceCase] =
		testWaitFiles.flatMap { file in
			literalHangGuards.map { source in
				SourceCase.rejects(
					"rejects a literal test hang guard in \(file): \(source)", [file: source],
					finding: "test-hang-guard-duration")
			} + [
				.accepts(
					"accepts named hang guards and explicit subject durations in \(file)",
					[file: namedHangGuards])
			]
		} + [
			.accepts(
				"leaves UI proof screen waits outside the test hang guard rule",
				[
					"apps/ios/EnduragentUITests/TutorialHarness.swift":
						"let deadline = ContinuousClock.now + .seconds(5)",
					"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Example.swift":
						"func operation(within limit: Duration = .seconds(5)) {}",
				])
		]

	static let observationWait = """
		while !condition() {
		  await withCheckedContinuation { continuation in
		    withObservationTracking {
		      if condition() { continuation.resume() }
		    } onChange: {
		      continuation.resume()
		    }
		  }
		}
		"""
	static let appWaitSupport = "apps/ios/EnduragentTests/WaitSupport.swift"
	static let withLockLoop =
		"while let changed = state.withLock({ state in state.changed }) "
		+ "{ try await changed.waitUnlessCancelled() }"

	static let waitDeadlines: [SourceCase] =
		[
			"while !ready { try await changed.waitUnlessCancelled() }",
			"try await beforeDeadline(within: .hangGuard) { return true }; "
				+ "while !ready { try await changed.waitUnlessCancelled() }",
			"while !ready { try await changed . waitUnlessCancelled () }",
			withLockLoop,
		].map { source in
			.rejects(
				"rejects an unbounded cancellable gate loop: \(source)",
				["\(coachTests)/WaitSupport.swift": source], finding: "test-wait-deadline")
		}
		+ [
			.rejects(
				"rejects an unbounded observation continuation loop",
				[appWaitSupport: observationWait], finding: "test-wait-deadline"),
			.accepts(
				"accepts an observation continuation loop inside a deadline",
				[
					appWaitSupport:
						"try await beforeDeadline(within: .hangGuard, onTimeout: { release() }) "
						+ "{ \(observationWait) }"
				]),
		]
		+ [
			"try await beforeDeadline(within: .hangGuard) "
				+ "{ while !ready { try await changed.waitUnlessCancelled() } }",
			"try await beforeDeadline(within: .hangGuard, onTimeout: { gate.release() }) "
				+ "{ \(withLockLoop) }",
			"while !ready, ContinuousClock.now < deadline { await Task.yield() }",
		].map { source in
			.accepts(
				"accepts a bounded gate loop: \(source)",
				["\(coachTests)/WaitSupport.swift": source])
		}

	static let exampleProof = "apps/ios/EnduragentUITests/ExampleProof.swift"
	static let tutorialHarness = "apps/ios/EnduragentUITests/TutorialHarness.swift"

	static let proofHelpers: [SourceCase] =
		[
			#"app.launchArguments = ["-EnduragentFixture", "first-week"]"#,
			"element.waitForExistence(timeout: 8)",
			"XCTWaiter.wait(for: [ready], timeout: 30)",
			"TutorialHarness.wait(element, timeout: 5)",
		].map { source in
			.rejects(
				"rejects UI proof configuration outside shared helpers: \(source)",
				[exampleProof: source], finding: "ui-proof-shared-helpers")
		}
		+ [
			.accepts(
				"accepts UI proofs using the argument builder and named waits",
				[
					exampleProof:
						"TutorialHarness.launch(app, arguments: FixtureArguments(store: .keep))\n"
						+ "TutorialHarness.wait(element, until: .hittable, within: .turn)"
				])
		]
		+ [
			"fixture.expire", "fixture.historyHead", "fixture.requestCount",
			"fixture.modelRequestCount", "debug.records", "debug.leases",
		].flatMap { identifier in
			[
				SourceCase.rejects(
					"rejects an unscrolled Debug row query: \(identifier)",
					[
						tutorialHarness:
							"let row = TutorialHarness.named(app, \"\(identifier)\")\n"
							+ "TutorialHarness.wait(row)\nrow.tap()"
					], finding: "ui-proof-debug-scrolling"),
				.accepts(
					"accepts a Debug row through bounded scrolling: \(identifier)",
					[
						tutorialHarness:
							"let row = TutorialHarness.debugRow(app, \"\(identifier)\", direction: .down)\n"
							+ "XCTAssertEqual(row.label, \"expected\")\nrow.tap()"
					]),
			]
		}
		+ [
			.rejects(
				"rejects skipped UI proofs", [exampleProof: #"throw XCTSkip("missing old store")"#],
				finding: "ui-proof-no-skips")
		]

	static let upgradeStore =
		"\(coachTests)/Fixtures/v1-upgrade/history/synced-records.store"
	static let sqliteStore = Array("SQLite format 3\0fixture".utf8)

	static let binaries: [SourceCase] =
		[.accepts("accepts committed upgrade SQLite stores", binaries: [upgradeStore: sqliteStore])]
		+ ["pre-vault-5de5c782", "build-2bbe2ee"].map { folder in
			.accepts(
				"accepts committed historical SQLite stores from \(folder)",
				binaries: [
					upgradeStore.replacingOccurrences(of: "v1-upgrade/history", with: folder):
						sqliteStore
				])
		}
		+ [
			.rejects(
				"rejects other binary files in upgrade resources",
				binaries: [upgradeStore: Array("arbitrary\0binary".utf8)],
				finding: "unexpected-binary"),
			.rejects(
				"rejects SQLite stores outside the two upgrade scenarios",
				binaries: [
					upgradeStore.replacingOccurrences(of: "/history/", with: "/other/"): sqliteStore
				], finding: "unexpected-binary"),
		]

	static let recordModel =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Records/StoredAthleteRecord.swift"
	static let registeredIndexes =
		#"#Index<StoredAthleteRecord>([\.deviceId, \.hlcWallMs, \.hlcLogical], [\.kind, \.chatId])"#
	static let ledgerIndexVersion = #"@Attribute(hashModifier: "ledger-indexes-v1")"#
	static let deviceId = "\nvar deviceId: String = \"\""

	static let ledgerIndexes: [SourceCase] =
		[
			#"#Index<StoredAthleteRecord>([\.deviceId, \.hlcWallMs, \.hlcLogical])"#,
			#"#Index<StoredAthleteRecord>([\.deviceId, \.hlcLogical, \.hlcWallMs], [\.kind, \.chatId])"#,
			#"#Index<StoredAthleteRecord>([\.deviceId, \.hlcWallMs, \.hlcLogical], [\.kind, \.chatId], [\.ulid])"#,
			"",
		].map { indexes in
			.rejects(
				"rejects changed ledger indexes with an unchanged model version: \(indexes)",
				[recordModel: "\(indexes)\n\(ledgerIndexVersion)\(deviceId)"],
				finding: "ledger-index-version")
		}
		+ [
			.accepts(
				"accepts the registered ledger index set and version",
				[recordModel: "\(registeredIndexes)\n\(ledgerIndexVersion)\(deviceId)"]),
			.rejects(
				"rejects unregistered ledger index versions",
				[
					recordModel:
						"\(registeredIndexes)\n@Attribute(hashModifier: \"ledger-indexes-v2\")\(deviceId)"
				], finding: "ledger-index-version"),
			.rejects(
				"rejects ledger indexes without a model version modifier",
				[recordModel: "\(registeredIndexes)\(deviceId)"], finding: "ledger-index-version"),
		]
}
