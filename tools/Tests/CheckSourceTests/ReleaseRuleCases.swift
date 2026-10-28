extension SourceCases {
	static let release = ReleaseTree()

	static func releaseFinding(_ file: String, _ rule: String, _ key: String) -> String {
		"\(file.quotedAsJSON) [\(rule)] \(key.quotedAsJSON)"
	}

	static func rejectsRelease(
		_ name: String, _ files: [String: String], _ file: String, _ rule: String,
		_ key: String
	) -> SourceCase {
		.rejects(
			name, files, finding: "[\(rule)]",
			findingLines: [releaseFinding(file, rule, key)])
	}

	static let releaseRules: [SourceCase] =
		privacyManifestRules + privacyLabelSheetRules + exportOptionsRules
		+ packageDependencyRules + knownHostsRules + noticeRules + supportedDevicesRules
		+ phoneTestsUnhostedRules

	static let privacyManifestRules: [SourceCase] = [
		.accepts("accepts release files that agree with each other", release.files),
		rejectsRelease(
			"privacy-manifest rejects a missing manifest",
			release.changed { $0.omitted = [ReleaseTree.manifestFile] },
			ReleaseTree.manifestFile, "privacy-manifest", "missing"),
		rejectsRelease(
			"privacy-manifest rejects a manifest the app target excludes",
			release.changed { $0.excludes = ["Info.plist", "*.xcprivacy"] },
			ReleaseTree.project, "privacy-manifest", "excludes"),
		rejectsRelease(
			"privacy-manifest rejects a manifest that declares tracking",
			release.changed { $0.tracking = true },
			ReleaseTree.manifestFile, "privacy-manifest", "NSPrivacyTracking"),
		rejectsRelease(
			"privacy-manifest rejects UserDefaults declared without CA92.1",
			release.changed { $0.accessed = [(ReleaseTree.defaults.0, []), ReleaseTree.bootTime] },
			ReleaseTree.manifestFile, "privacy-manifest", ReleaseTree.defaults.0),
		rejectsRelease(
			"privacy-manifest rejects a manifest without the UserDefaults entry the code needs",
			release.changed { $0.accessed = [ReleaseTree.bootTime] },
			ReleaseTree.manifestFile, "privacy-manifest", ReleaseTree.defaults.0),
		rejectsRelease(
			"privacy-manifest rejects a third accessed API type",
			release.changed {
				$0.accessed.append(("NSPrivacyAccessedAPICategoryFileTimestamp", ["C617.1"]))
			},
			ReleaseTree.manifestFile, "privacy-manifest",
			"NSPrivacyAccessedAPICategoryFileTimestamp"),
		rejectsRelease(
			"privacy-manifest rejects a product file that reads a file date",
			release.changed {
				$0.sources["\(coachSources)/Support/Pruning.swift"] =
					"let date = values.modificationDate\n"
			},
			"\(coachSources)/Support/Pruning.swift", "privacy-manifest",
			"NSPrivacyAccessedAPICategoryFileTimestamp"),
		rejectsRelease(
			"privacy-manifest rejects an app file that reads the free disk space",
			release.changed {
				$0.sources["apps/ios/Enduragent/App/Space.swift"] =
					"let key = URLResourceKey.volumeAvailableCapacityKey\n"
			},
			"apps/ios/Enduragent/App/Space.swift", "privacy-manifest",
			"NSPrivacyAccessedAPICategoryDiskSpace"),
		rejectsRelease(
			"privacy-manifest rejects UserDefaults declared over sources that never use it",
			release.changed { $0.sources["apps/ios/Enduragent/App/DraftStore.swift"] = nil },
			ReleaseTree.manifestFile, "privacy-manifest", ReleaseTree.defaults.0),
		.accepts(
			"privacy-manifest accepts a test file that reads a file date",
			release.changed {
				$0.sources["\(coachTests)/PruningTests.swift"] = "let date = values.creationDate\n"
			}),
	]

	static let privacyLabelSheetRules: [SourceCase] = [
		rejectsRelease(
			"privacy-label-sheet rejects a manifest type the sheet leaves out",
			release.changed {
				$0.declared.append(CollectedType(type: "NSPrivacyCollectedDataTypeHealth"))
			},
			ReleaseTree.sheetFile, "privacy-label-sheet", "NSPrivacyCollectedDataTypeHealth"),
		rejectsRelease(
			"privacy-label-sheet rejects a sheet type the manifest leaves out",
			release.changed {
				$0.answered.append(CollectedType(type: "NSPrivacyCollectedDataTypeUserID"))
			},
			ReleaseTree.sheetFile, "privacy-label-sheet", "NSPrivacyCollectedDataTypeUserID"),
		rejectsRelease(
			"privacy-label-sheet rejects a linked answer that differs",
			release.changed { $0.answered[1].linked = true },
			ReleaseTree.sheetFile, "privacy-label-sheet", ReleaseTree.support.type),
		.rejects(
			"privacy-label-sheet rejects tracking in the sheet only",
			release.changed { $0.answered[0].tracking = true }, finding: "[privacy-label-sheet]",
			findingLines: [
				releaseFinding(
					ReleaseTree.sheetFile, "privacy-label-sheet", ReleaseTree.fitness.type),
				releaseFinding(
					ReleaseTree.sheetFile, "privacy-label-sheet", ReleaseTree.fitness.type),
			]),
		rejectsRelease(
			"privacy-label-sheet rejects an Analytics purpose in the manifest only",
			release.changed {
				$0.declared[0].purposes.append("NSPrivacyCollectedDataTypePurposeAnalytics")
			},
			ReleaseTree.sheetFile, "privacy-label-sheet", ReleaseTree.fitness.type),
		rejectsRelease(
			"privacy-label-sheet rejects a sheet that says the app tracks",
			release.changed { $0.sheetTracking = true },
			ReleaseTree.sheetFile, "privacy-label-sheet", "tracking"),
	]

	static let exportOptionsRules: [SourceCase] = [
		rejectsRelease(
			"export-options rejects a method other than app-store-connect",
			release.changed { $0.export[0] = "ad-hoc" },
			ReleaseTree.exportFile, "export-options", "method"),
		rejectsRelease(
			"export-options rejects manual signing",
			release.changed { $0.export[1] = "manual" },
			ReleaseTree.exportFile, "export-options", "signingStyle"),
		rejectsRelease(
			"export-options rejects a team other than the project's",
			release.changed { $0.export[2] = "ABCDE12345" },
			ReleaseTree.exportFile, "export-options", "teamID"),
	]

	static let packageDependencyRules: [SourceCase] = [
		.rejects(
			"no-app-package-dependency rejects a second package in project.yml",
			release.changed { $0.packages.append("Alamofire") },
			finding: "[no-app-package-dependency]",
			findingLines: [
				releaseFinding(ReleaseTree.project, "no-app-package-dependency", "Alamofire"),
				releaseFinding(ReleaseTree.project, "no-app-package-dependency", "Alamofire"),
			]),
		rejectsRelease(
			"no-app-package-dependency rejects a package-level dependencies argument",
			release.changed {
				$0.packageArguments = "\tdependencies: [],\n" + ReleaseTree.targetPackages
			},
			ReleaseTree.packageFile, "no-app-package-dependency", "dependencies"),
		.rejects(
			"no-app-package-dependency rejects a .package call",
			release.changed {
				$0.packageArguments =
					"\tdependencies: [.package(path: \"../Other\")],\n" + ReleaseTree.targetPackages
			}, finding: "[no-app-package-dependency]",
			findingLines: [
				releaseFinding(ReleaseTree.packageFile, "no-app-package-dependency", ".package("),
				releaseFinding(
					ReleaseTree.packageFile, "no-app-package-dependency", "dependencies"),
			]),
	]
	static let knownHostsRules: [SourceCase] = [
		rejectsRelease(
			"known-hosts rejects an App Store lookup URL in product Swift",
			release.changed {
				$0.sources["\(coachSources)/Support/Update.swift"] =
					"let lookup = URL(string: \"https://itunes.apple.com/lookup?bundleId=x\")\n"
			},
			"\(coachSources)/Support/Update.swift", "known-hosts", "itunes.apple.com"),
		rejectsRelease(
			"known-hosts rejects a host given to URLComponents",
			release.changed {
				$0.sources["apps/ios/Enduragent/App/Update.swift"] =
					"var parts = URLComponents()\nparts.host = \"itunes.apple.com\"\n"
			},
			"apps/ios/Enduragent/App/Update.swift", "known-hosts", "itunes.apple.com"),
		rejectsRelease(
			"known-hosts rejects a plain http URL to an unlisted host",
			release.changed {
				$0.sources["\(coachSources)/Support/Ping.swift"] =
					"let ping = \"http://example.com\"\n"
			},
			"\(coachSources)/Support/Ping.swift", "known-hosts", "example.com"),
		rejectsRelease(
			"known-hosts rejects an update URL in the app's Info properties",
			release.changed {
				$0.properties.append("UpdateURL: https://itunes.apple.com/lookup")
			},
			ReleaseTree.project, "known-hosts", "itunes.apple.com"),
		rejectsRelease(
			"known-hosts rejects an Info property whose build setting names an unlisted host",
			release.changed { $0.creditsBase = "https://credits.example.com" },
			ReleaseTree.project, "known-hosts", "credits.example.com"),
		.accepts(
			"known-hosts accepts the Credits worker base and hosts outside product Swift",
			release.changed {
				$0.sources["apps/ios/Enduragent/Settings/RecordsDebugView.swift"] =
					"let probe = \"https://example.com\"\n"
				$0.sources["\(coachFixtures)/FixtureHosts.swift"] = "let host = \"example.com\"\n"
				$0.sources["\(coachTests)/HostTests.swift"] = "let host = \"itunes.apple.com\"\n"
			}),
	]

	static let noticeRules: [SourceCase] = [
		rejectsRelease(
			"notice-iphone-line rejects a NOTICE.md without the iPhone line",
			release.changed { $0.notice = "Nothing here about the iPhone app." },
			"NOTICE.md", "notice-iphone-line", "missing"),
		rejectsRelease(
			"notice-iphone-line rejects a file under apps that names fit-file-parser",
			release.changed {
				$0.sources["apps/ios/Enduragent/App/Import.swift"] =
					"let parser = \"fit-file-parser\"\n"
			},
			"apps/ios/Enduragent/App/Import.swift", "notice-iphone-line", "fit-file-parser"),
		rejectsRelease(
			"notice-iphone-line rejects a file under packages that names pi-ai",
			release.changed { $0.sources["packages/i18n/README.md"] = "Copied from pi-ai.\n" },
			"packages/i18n/README.md", "notice-iphone-line", "pi-ai"),
	]

	static let supportedDevicesRules: [SourceCase] = [
		rejectsRelease(
			"supported-devices rejects deployment target 25.0",
			release.changed { $0.deploymentTarget = "\"25.0\"" },
			ReleaseTree.project, "supported-devices", "deploymentTarget"),
		rejectsRelease(
			"supported-devices rejects iPad in the device family",
			release.changed { $0.deviceFamily = "\"1,2\"" },
			ReleaseTree.project, "supported-devices", "TARGETED_DEVICE_FAMILY"),
		rejectsRelease(
			"supported-devices rejects a landscape orientation",
			release.changed {
				$0.orientations =
					"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft"
			},
			ReleaseTree.project, "supported-devices", "UISupportedInterfaceOrientations"),
	]

	static let phoneTestsUnhostedRules: [SourceCase] = [
		rejectsRelease(
			"phone-tests-unhosted rejects TEST_TARGET_NAME on the phone test target",
			release.changed { $0.phoneTestSettings.append("TEST_TARGET_NAME: Enduragent") },
			ReleaseTree.project, "phone-tests-unhosted", "TEST_TARGET_NAME"),
		rejectsRelease(
			"phone-tests-unhosted rejects a phone test target that depends on the app",
			release.changed { $0.phoneTestDependencies.insert("target: Enduragent", at: 0) },
			ReleaseTree.project, "phone-tests-unhosted", "dependencies"),
		rejectsRelease(
			"phone-tests-unhosted rejects a phone scheme that builds the app",
			release.changed { $0.phoneSchemeTargets.insert("Enduragent: all", at: 0) },
			ReleaseTree.project, "phone-tests-unhosted", "schemes"),
	]
}
