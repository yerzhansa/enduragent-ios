struct CollectedType {
	let type: String
	var linked = true
	var tracking = false
	var purposes = ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
}

struct ReleaseTree {
	static let project = "apps/ios/project.yml"
	static let manifestFile = "apps/ios/Enduragent/PrivacyInfo.xcprivacy"
	static let sheetFile = "release/app-privacy.json"
	static let exportFile = "ExportOptions.plist"
	static let packageFile = "apps/ios/Packages/EnduragentCoach/Package.swift"
	static let noticeLine =
		"The iPhone app (`apps/ios`) ships none of the code this file lists"
		+ " and has no third-party package."
	static let fitness = CollectedType(type: "NSPrivacyCollectedDataTypeFitness")
	static let support = CollectedType(
		type: "NSPrivacyCollectedDataTypeCustomerSupport", linked: false)
	static let defaults = ("NSPrivacyAccessedAPICategoryUserDefaults", ["CA92.1"])
	static let bootTime = ("NSPrivacyAccessedAPICategorySystemBootTime", ["35F9.1"])
	static let targetPackages =
		"\ttargets: [\n\t\t.target(name: \"EnduragentCoach\"),\n"
		+ "\t\t.target(name: \"EnduragentCoachFixtures\", dependencies: [\"EnduragentCoach\"]),\n"
		+ "\t]\n"

	var deploymentTarget = "\"26.0\""
	var deviceFamily = "\"1\""
	var orientations = "UIInterfaceOrientationPortrait"
	var excludes = ["Info.plist"]
	var creditsBase = "https://enduragent-credits-testflight.yerzhan-st.workers.dev"
	var properties = ["CreditsWorkerBase: $(CREDITS_WORKER_BASE)"]
	var packages = ["EnduragentCoach"]
	var packageArguments = targetPackages
	var tracking = false
	var accessed = [defaults, bootTime]
	var declared = [fitness, support]
	var answered = [fitness, support]
	var sheetTracking = false
	var export = ["app-store-connect", "automatic", "FA494ACVTF"]
	var notice = noticeLine
	var sources = [
		"\(SourceCases.coachSources)/Clock.swift":
			"let uptime = DispatchTime.now().uptimeNanoseconds\n",
		"apps/ios/Enduragent/App/DraftStore.swift": "let store = UserDefaults.standard\n",
		"\(SourceCases.coachSources)/CoachPorts.swift":
			"let base = URL(string: \"https://openrouter.ai/api/v1\")\n"
			+ "let link = \"intervals.icu\"\n",
	]
	var omitted: [String] = []

	var files: [String: String] {
		var files = sources
		files[Self.project] = projectText
		files[Self.manifestFile] = manifestText
		files[Self.sheetFile] = sheetText
		files[Self.exportFile] = plist(
			zip(["method", "signingStyle", "teamID"], export).map {
				"\t<key>\($0.0)</key>\n\t<string>\($0.1)</string>\n"
			}.joined())
		files[Self.packageFile] =
			"let package = Package(\n\tname: \"EnduragentCoach\",\n\(packageArguments))\n"
		files["NOTICE.md"] = "# Notices and Attributions\n\n\(notice)\n"
		for file in omitted { files[file] = nil }
		return files
	}

	private var projectText: String {
		"name: Enduragent\noptions:\n  deploymentTarget:\n    iOS: \"26.0\"\nsettings:\n  base:\n"
			+ "    DEVELOPMENT_TEAM: FA494ACVTF\npackages:\n"
			+ packages.map { "  \($0):\n    path: Packages/\($0)\n" }.joined()
			+ "targets:\n  Enduragent:\n    type: application\n"
			+ "    deploymentTarget: \(deploymentTarget)\n    sources:\n      - path: Enduragent\n"
			+ "        excludes:\n" + excludes.map { "          - \($0)\n" }.joined()
			+ "    settings:\n      base:\n        CREDITS_WORKER_BASE: \(creditsBase)\n"
			+ "        INFOPLIST_KEY_UISupportedInterfaceOrientations: \(orientations)\n"
			+ "        TARGETED_DEVICE_FAMILY: \(deviceFamily)\n"
			+ "        DEVELOPMENT_TEAM: FA494ACVTF\n    info:\n      properties:\n"
			+ properties.map { "        \($0)\n" }.joined() + "    dependencies:\n"
			+ packages.map { "      - package: \($0)\n" }.joined()
			+ "      - package: EnduragentCoach\n        product: EnduragentCoachFixtures\n"
	}

	private var manifestText: String {
		plist(
			"\t<key>NSPrivacyTracking</key>\n\t<\(tracking)/>\n"
				+ "\t<key>NSPrivacyTrackingDomains</key>\n\t<array/>\n"
				+ "\t<key>NSPrivacyCollectedDataTypes</key>\n\t<array>\n"
				+ declared.map {
					"\t\t<dict>\n\t\t\t<key>NSPrivacyCollectedDataType</key>\n"
						+ "\t\t\t<string>\($0.type)</string>\n"
						+ "\t\t\t<key>NSPrivacyCollectedDataTypeLinked</key>\n\t\t\t<\($0.linked)/>\n"
						+ "\t\t\t<key>NSPrivacyCollectedDataTypeTracking</key>\n"
						+ "\t\t\t<\($0.tracking)/>\n"
						+ "\t\t\t<key>NSPrivacyCollectedDataTypePurposes</key>\n"
						+ strings($0.purposes) + "\t\t</dict>\n"
				}.joined() + "\t</array>\n\t<key>NSPrivacyAccessedAPITypes</key>\n\t<array>\n"
				+ accessed.map {
					"\t\t<dict>\n\t\t\t<key>NSPrivacyAccessedAPIType</key>\n"
						+ "\t\t\t<string>\($0.0)</string>\n"
						+ "\t\t\t<key>NSPrivacyAccessedAPITypeReasons</key>\n" + strings($0.1)
						+ "\t\t</dict>\n"
				}.joined() + "\t</array>\n")
	}

	private var sheetText: String {
		"{\n\t\"tracking\": \(sheetTracking),\n\t\"collected\": [\n"
			+ answered.map {
				"\t\t{\"type\": \"\($0.type)\", \"linked\": \($0.linked), "
					+ "\"tracking\": \($0.tracking), \"purposes\": ["
					+ $0.purposes.map { "\"\($0)\"" }.joined(separator: ", ") + "]}"
			}.joined(separator: ",\n") + "\n\t]\n}\n"
	}

	private func strings(_ values: [String]) -> String {
		"\t\t\t<array>\n" + values.map { "\t\t\t\t<string>\($0)</string>\n" }.joined()
			+ "\t\t\t</array>\n"
	}

	private func plist(_ body: String) -> String {
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n"
			+ body + "</dict>\n</plist>\n"
	}

	func changed(_ change: (inout ReleaseTree) -> Void) -> [String: String] {
		var tree = self
		change(&tree)
		return tree.files
	}
}
