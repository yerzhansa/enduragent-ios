extension SourceCases {
	static let links: [SourceCase] = [
		.accepts(
			"accepts a relative skill-directory link to tracked content without reading the link entry as content",
			[".agents/skills/check/SKILL.md": "# Check\n"],
			links: [".claude/skills": .relative("../.agents/skills")]),
		.accepts(
			"accepts a relative link to a tracked file without reading the link entry as content",
			["payload.txt": "technical CTL"], links: ["first.md": .relative("payload.txt")]),
		.accepts(
			"accepts a tracked two-link chain inside the repository without reading the link entry as content",
			["payload.txt": "content"],
			links: ["first": .relative("second"), "second": .relative("payload.txt")]),
		.accepts(
			"accepts a tracked directory link in a target path without reading the link entry as content",
			["folder/payload.txt": "content"],
			links: ["first": .relative("second/payload.txt"), "second": .relative("folder")]),
		.accepts(
			"accepts parent traversal after resolving a directory link without reading the link entry as content",
			["nested/payload.txt": "content", "nested/deep/keep.txt": "content"],
			links: [
				"first": .relative("second/../payload.txt"), "second": .relative("nested/deep"),
			]),
		unsafeLink(
			"an absolute link to tracked content inside the repository", ["payload.txt": "content"],
			links: ["first": .insideRepository("payload.txt")]),
		unsafeLink("a relative link outside the repository", links: ["first": .relative("..")]),
		unsafeLink("a dangling link", links: ["first": .relative("missing.txt")]),
		unsafeLink(
			"a link to an untracked file", ["payload.txt": "content"],
			links: ["first": .relative("payload.txt")], tracked: .only(["first"])),
		unsafeLink(
			"a link to a directory containing only untracked files",
			["folder/payload.txt": "content"], links: ["first": .relative("folder")],
			tracked: .only(["first"])),
		unsafeLink(
			"a tracked two-link chain ending outside the repository",
			links: ["first": .relative("second"), "second": .relative("..")]),
		unsafeLink(
			"an untracked intermediate link to tracked content", ["payload.txt": "content"],
			links: ["first": .relative("second"), "second": .relative("payload.txt")],
			tracked: .only(["first", "payload.txt"])),
		unsafeLink(
			"an absolute intermediate link to tracked content", ["payload.txt": "content"],
			links: ["first": .relative("second"), "second": .insideRepository("payload.txt")]),
		unsafeLink(
			"a cyclic link chain",
			links: ["first": .relative("second"), "second": .relative("first")]),
	]

	private static func unsafeLink(
		_ name: String, _ files: [String: String] = [:], links: [String: Link],
		tracked: Tracked = .everything
	) -> SourceCase {
		.rejects(
			"rejects \(name) as an unsafe path", files, links: links, tracked: tracked,
			finding: #""first" [unsafe-path]"#)
	}

	static let xcodeProject = "apps/ios/Enduragent.xcodeproj/project.pbxproj"
	static let proofEntitlements = "apps/ios/Enduragent/KeychainProof.entitlements"
	static let sharedBuildSettings = [
		"DEVELOPMENT_TEAM": "FA494ACVTF", "CODE_SIGN_STYLE": "Automatic", "SWIFT_VERSION": "6.0",
	]
	static let isolatedEntitlements =
		#"{"keychain-access-groups":["$(AppIdentifierPrefix)icu.enduragent.keychainproof"]}"#
	static let ordinaryKeychain =
		#"{"keychain-access-groups":["$(AppIdentifierPrefix)icu.enduragent.app"]}"#
	static let cloudEntitlements =
		#"{"keychain-access-groups":["$(AppIdentifierPrefix)icu.enduragent.keychainproof"],"#
		+ #""com.apple.developer.icloud-container-identifiers":["iCloud.icu.enduragent.ios"],"#
		+ #""com.apple.developer.icloud-services":["CloudKit"]}"#

	private static func object(_ members: [String: String]) -> String {
		let pairs = members.sorted { $0.key < $1.key }.map { #""\#($0.key)":"\#($0.value)""# }
		return "{\(pairs.joined(separator: ","))}"
	}

	static func phoneProjectFiles(
		settings: [String: String] = sharedBuildSettings,
		entitlements: String = isolatedEntitlements
	) -> [String: String] {
		let appSettings = sharedBuildSettings.merging([
			"PRODUCT_BUNDLE_IDENTIFIER": "icu.enduragent.keychainproof",
			"CODE_SIGN_ENTITLEMENTS": "Enduragent/KeychainProof.entitlements",
		]) { $1 }
		let project = """
			{"rootObject":"project","objects":{
			"project":{"buildConfigurationList":"projectConfigs","targets":["app","phoneTests"]},
			"projectConfigs":{"buildConfigurations":["projectProof"]},
			"projectProof":{"name":"DebugKeychainProof","buildSettings":\(object(settings))},
			"app":{"productType":"com.apple.product-type.application",
			"buildConfigurationList":"appConfigs"},
			"appConfigs":{"buildConfigurations":["appProof"]},
			"appProof":{"name":"DebugKeychainProof","buildSettings":\(object(appSettings))},
			"phoneTests":{"productType":"com.apple.product-type.bundle.ui-testing",
			"buildConfigurationList":"testConfigs"},
			"testConfigs":{"buildConfigurations":["testProof"]},
			"testProof":{"name":"DebugKeychainProof","buildSettings":{}}}}
			"""
		return [xcodeProject: project, proofEntitlements: entitlements]
	}

	static let xcodeSettings: [SourceCase] =
		[
			.accepts(
				"accepts isolated proof entitlements and inherited phone-test settings",
				phoneProjectFiles())
		]
		+ [ordinaryKeychain, cloudEntitlements].map { entitlements in
			.rejects(
				"rejects proof access to ordinary storage: \(entitlements)",
				phoneProjectFiles(entitlements: entitlements),
				finding: "keychain-proof-storage-isolation")
		}
		+ ["DEVELOPMENT_TEAM", "CODE_SIGN_STYLE", "SWIFT_VERSION"].map { setting in
			.rejects(
				"rejects dropped shared phone-test settings: \(setting)",
				phoneProjectFiles(settings: sharedBuildSettings.filter { $0.key != setting }),
				finding: "xcode-shared-build-settings")
		}
		+ [
			.rejects(
				"rejects dropped shared settings in a generated project that is not tracked",
				phoneProjectFiles(settings: [:]), tracked: .only([proofEntitlements]),
				finding: "xcode-shared-build-settings")
		]

	static let navigationRoot = "apps/ios/Enduragent/Chat/ChatView.swift"
	static let navigationChild = "apps/ios/Enduragent/Settings/SettingsView.swift"
	static let boundNavigation = """
		struct ChatView: View {
		  var body: some View {
		    NavigationStack(path: $model.navigation) {
		      Text(title).navigationDestination(for: ShellDestination.self) { destination in
		        SettingsView(model: model)
		      }
		    }
		  }
		}
		"""
	static let stackOwner = "shell-navigation-stack-owner"
	static let sheetView =
		"struct SheetView: View { var body: some View { NavigationStack { Text(title) } } }"
	static let pushedWithSheet =
		"struct SettingsView: View { var body: some View { "
		+ "Text(title).sheet(item: $selection) { item in SheetView() } } }"

	static let navigationStacks: [SourceCase] = [
		.rejects(
			"rejects a NavigationStack in a pushed view",
			[
				navigationRoot: boundNavigation,
				navigationChild:
					"struct SettingsView: View { var body: some View { NavigationStack { Text(title) } } }",
			], finding: stackOwner),
		.rejects(
			"rejects a NavigationStack reached through a pushed view and its link",
			[
				navigationRoot: boundNavigation,
				navigationChild:
					"struct SettingsView: View { var body: some View { NavigationLink(title) { RecordsView() } } }",
				"apps/ios/Enduragent/Records/RecordsView.swift":
					"struct RecordsView: View { var body: some View { NavigationStack { Text(title) } } }",
			],
			finding:
				#"apps/ios/Enduragent/Records/RecordsView.swift" [shell-navigation-stack-owner]"#),
		.rejects(
			"rejects a second stack inside the bound shell stack",
			[
				navigationRoot:
					"struct ChatView: View { var body: some View { NavigationStack(path: $model.navigation) "
					+ "{ NavigationStack { Text(title) } } } }"
			], finding: stackOwner),
		.accepts(
			"accepts a sheet owning an inline NavigationStack from a pushed view",
			[
				navigationRoot: boundNavigation,
				navigationChild:
					"struct SettingsView: View { var body: some View { "
					+ "Text(title).sheet(isPresented: $show) { NavigationStack { Text(title) } } } }",
			]),
		SourceCase(
			name:
				"accepts a sheet owning a separate stack view without exempting its pushed sibling",
			runs: [
				Scratch(files: [
					navigationRoot: boundNavigation, navigationChild: pushedWithSheet + sheetView,
				]),
				Scratch(
					files: [
						navigationRoot: boundNavigation,
						navigationChild:
							pushedWithSheet.replacingOccurrences(
								of: "Text(title).sheet",
								with: "NavigationStack { Text(title) }.sheet")
							+ sheetView,
					], status: 1, findings: [stackOwner]),
			]),
		.rejects(
			"rejects a stack outside nested sheets",
			[
				navigationRoot: boundNavigation,
				navigationChild: """
				struct SettingsView: View {
				      var body: some View {
				        Text(title).sheet(isPresented: $show) {
				          NavigationStack { Text(title).sheet(isPresented: $other) { NavigationStack { Text(title) } } }
				        }
				        NavigationStack { Text(title) }
				      }
				    }
				""",
			], finding: stackOwner),
		.accepts(
			"accepts independent onboarding stacks and NavigationStack inside a string",
			[
				navigationRoot: boundNavigation,
				navigationChild:
					#"struct SettingsView: View { var body: some View { Text("NavigationStack { RecordsView() }") } }"#,
				"apps/ios/Enduragent/Onboarding/NoticeView.swift":
					"struct NoticeView: View { var body: some View { NavigationStack { Text(title) } } }",
			]),
	]
}
