import ToolSupport

struct RequiredReasonAPI {
	let category: String
	let reasons: [String]
	let patterns: [String]

	static let all: [RequiredReasonAPI] = [
		RequiredReasonAPI(
			category: "NSPrivacyAccessedAPICategoryUserDefaults", reasons: ["CA92.1"],
			patterns: [#"\bUserDefaults\b"#, #"@AppStorage\b"#]),
		RequiredReasonAPI(
			category: "NSPrivacyAccessedAPICategorySystemBootTime", reasons: ["35F9.1"],
			patterns: [
				#"\bsystemUptime\b"#, #"\bContinuousClock\b"#, #"\bmach_absolute_time\b"#,
				#"\buptimeNanoseconds\b"#,
			]),
		RequiredReasonAPI(
			category: "NSPrivacyAccessedAPICategoryFileTimestamp", reasons: [],
			patterns: [
				#"\.creationDate\b"#, #"\.modificationDate\b"#, #"contentModificationDate"#,
				#"\battributesOfItem\b"#, #"\bgetattrlist\b"#,
			]),
		RequiredReasonAPI(
			category: "NSPrivacyAccessedAPICategoryDiskSpace", reasons: [],
			patterns: [#"volumeAvailableCapacity"#, #"\bstatfs\b"#]),
		RequiredReasonAPI(
			category: "NSPrivacyAccessedAPICategoryActiveKeyboards", reasons: [],
			patterns: [#"\bactiveInputModes\b"#]),
	]
}

struct KnownHost {
	let name: String
	let reason: String

	static let all: [KnownHost] = [
		KnownHost(name: "openrouter.ai", reason: "OpenRouter chat calls and its sign-in page"),
		KnownHost(name: "api.enduragent.icu", reason: "The model catalog"),
		KnownHost(
			name: "enduragent.icu", reason: "The OpenRouter sign-in callback and the privacy policy"
		),
		KnownHost(name: "feedback.enduragent.icu", reason: "Feedback notes"),
		KnownHost(name: "intervals.icu", reason: "The athlete's training data"),
		KnownHost(
			name: "credits.enduragent.icu",
			reason: "The Credits worker base, the CREDITS_WORKER_BASE build setting"),
	]
}

private struct CollectedAnswer: Equatable {
	let linked: Bool?
	let tracking: Bool?
	let purposes: [String]
}

extension SourceChecker {
	static let releaseInput =
		#"^(?:apps\/|packages\/|NOTICE\.md$|ExportOptions\.plist$|release\/app-privacy\.json$)"#
	static let productSwift =
		#"^apps\/ios\/(?:Packages\/EnduragentCoach\/Sources\/EnduragentCoach|Enduragent)\/"#
		+ #".*\.swift$"#
	static let privacyManifest = "apps/ios/Enduragent/PrivacyInfo.xcprivacy"
	static let exportOptions = "ExportOptions.plist"
	static let labelSheet = "release/app-privacy.json"
	static let notice = "NOTICE.md"
	static let noticeIPhoneLine =
		"The iPhone app (`apps/ios`) ships none of the code this file lists"
		+ " and has no third-party package."
	static let shippedNames = #"(?:^|[^\w\-])(section-11|pi-ai|fit-file-parser)(?![\w\-])"#
	static let hostShaped = #"^(?:[a-z0-9\-]+\.)+(?:com|net|org|io|icu|ai|app|dev)$"#

	func checkRelease(_ sources: [SourceFile]) throws {
		func source(_ file: String) -> SourceFile? {
			sources.first { $0.file.hasSameUnits(as: file) }
		}
		guard let project = source(Self.appProject) else { return }
		let spec = try ProjectSpec(project.text, patterns: patterns)
		let product = try sources.filter { try patterns.test(Self.productSwift, $0.file) }
		let manifest = try checkPrivacyManifest(
			source(Self.privacyManifest) != nil, spec: spec, product: product)
		try checkLabelSheet(source(Self.labelSheet), manifest: manifest)
		try checkExportOptions(source(Self.exportOptions) != nil, spec: spec)
		try checkPackageDependencies(spec, source(Self.coachPackageManifest))
		try checkKnownHosts(product, spec: spec)
		try checkNotice(source(Self.notice), sources: sources)
		try checkSupportedDevices(spec)
		try checkPhoneTestsUnhosted(spec)
	}

	private func plist(_ file: String) throws -> JSONValue {
		try readPlist(NodePath.resolve(root, file))
	}

	private func list(_ value: JSONValue) -> [JSONValue] {
		guard case .array(let elements) = value else { return [] }
		return elements
	}

	private func strings(_ value: JSONValue) -> [String] {
		list(value).compactMap { element in
			guard case .string(let text) = element else { return nil }
			return text
		}
	}

	private func flag(_ value: JSONValue) -> Bool? {
		guard case .bool(let flag) = value else { return nil }
		return flag
	}

	private func checkPrivacyManifest(
		_ present: Bool, spec: ProjectSpec, product: [SourceFile]
	) throws -> JSONValue? {
		let rule = "privacy-manifest"
		let manifestName = NodePath.basename(Self.privacyManifest)
		for glob in spec.values(ProjectSpec.app + ["sources", "-", "excludes", "-"])
		where try patterns.test(globPattern(glob), manifestName) {
			try findings.report(Self.appProject, rule, key: "excludes")
		}
		guard present else {
			try findings.report(Self.privacyManifest, rule, key: "missing")
			return nil
		}
		let manifest = try plist(Self.privacyManifest)
		if try flag(manifest.member("NSPrivacyTracking")) != false {
			try findings.report(Self.privacyManifest, rule, key: "NSPrivacyTracking")
		}
		let domains = try manifest.member("NSPrivacyTrackingDomains")
		if !domains.isSamePrimitive(as: .undefined) && !isEmptyList(domains) {
			try findings.report(Self.privacyManifest, rule, key: "NSPrivacyTrackingDomains")
		}
		let codes = try product.map { (file: $0.file, code: try patterns.withoutStrings($0.text)) }
		var required: [String: [String]] = [:]
		for api in RequiredReasonAPI.all {
			for file in codes {
				guard try api.patterns.contains(where: { try patterns.test($0, file.code) }) else {
					continue
				}
				if api.reasons.isEmpty {
					try findings.report(file.file, rule, key: api.category)
				} else {
					required[api.category] = api.reasons
				}
			}
		}
		var declared: Set<String> = []
		for entry in try list(manifest.member("NSPrivacyAccessedAPITypes")) {
			guard case .string(let category) = try entry.member("NSPrivacyAccessedAPIType") else {
				try findings.report(Self.privacyManifest, rule, key: "NSPrivacyAccessedAPIType")
				continue
			}
			let reasons = try strings(entry.member("NSPrivacyAccessedAPITypeReasons"))
			if declared.contains(category) || required[category] != reasons {
				try findings.report(Self.privacyManifest, rule, key: category)
			}
			declared.insert(category)
		}
		for category in required.keys.sorted() where !declared.contains(category) {
			try findings.report(Self.privacyManifest, rule, key: category)
		}
		return manifest
	}

	private func isEmptyList(_ value: JSONValue) -> Bool {
		guard case .array(let elements) = value else { return false }
		return elements.isEmpty
	}

	private func globPattern(_ glob: String) -> String {
		var pattern = "^"
		var rest = Substring(glob)
		while let first = rest.first {
			if rest.hasPrefix("**/") {
				pattern += #"(?:.*\/)?"#
				rest = rest.dropFirst(3)
				continue
			}
			switch first {
			case "*": pattern += #"[^\/]*"#
			case "?": pattern += #"[^\/]"#
			case "/": pattern += #"\/"#
			case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
				pattern += #"\"# + String(first)
			default: pattern += String(first)
			}
			rest = rest.dropFirst()
		}
		return pattern + "$"
	}

	private func collectedAnswers(
		_ entries: [JSONValue], typeKey: String, answerKeys: (String, String, String),
		file: String
	) throws -> [String: CollectedAnswer] {
		var answers: [String: CollectedAnswer] = [:]
		for entry in entries {
			guard case .string(let type) = try entry.member(typeKey) else {
				try findings.report(file, "privacy-label-sheet", key: typeKey)
				continue
			}
			if answers[type] != nil { try findings.report(file, "privacy-label-sheet", key: type) }
			answers[type] = CollectedAnswer(
				linked: try flag(entry.member(answerKeys.0)),
				tracking: try flag(entry.member(answerKeys.1)),
				purposes: try strings(entry.member(answerKeys.2)).sorted())
		}
		return answers
	}

	private func checkLabelSheet(_ sheet: SourceFile?, manifest: JSONValue?) throws {
		let rule = "privacy-label-sheet"
		guard let sheet else {
			try findings.report(Self.labelSheet, rule, key: "missing")
			return
		}
		let answers = try JSONValue.parse(sheet.text)
		if try flag(answers.member("tracking")) != false {
			try findings.report(Self.labelSheet, rule, key: "tracking")
		}
		let listed = try collectedAnswers(
			list(answers.member("collected")), typeKey: "type",
			answerKeys: ("linked", "tracking", "purposes"), file: Self.labelSheet)
		for (type, answer) in listed where answer.tracking != false {
			try findings.report(Self.labelSheet, rule, key: type)
		}
		guard let manifest else { return }
		let declared = try collectedAnswers(
			list(manifest.member("NSPrivacyCollectedDataTypes")),
			typeKey: "NSPrivacyCollectedDataType",
			answerKeys: (
				"NSPrivacyCollectedDataTypeLinked", "NSPrivacyCollectedDataTypeTracking",
				"NSPrivacyCollectedDataTypePurposes"
			), file: Self.privacyManifest)
		for type in Set(listed.keys).union(declared.keys).sorted()
		where listed[type] != declared[type] {
			try findings.report(Self.labelSheet, rule, key: type)
		}
	}

	private func checkExportOptions(_ present: Bool, spec: ProjectSpec) throws {
		let rule = "export-options"
		guard present else {
			try findings.report(Self.exportOptions, rule, key: "missing")
			return
		}
		let options = try plist(Self.exportOptions)
		let team = spec.values(ProjectSpec.app + ["settings", "base", "DEVELOPMENT_TEAM"]).first
		let expected = [
			("method", "app-store-connect"), ("signingStyle", "automatic"),
			("teamID", team ?? ""),
		]
		for (key, value) in expected where try value.isEmpty || !options.member(key).isString(value)
		{
			try findings.report(Self.exportOptions, rule, key: key)
		}
	}

	private func hosts(in text: String) throws -> [String] {
		let named = try patterns.matchAll(#"https?:\/\/([^\/\s"?#:]*)"#, text).map {
			$0.groups[1].lowercased()
		}
		let whole = text.lowercased()
		return try named + (patterns.test(Self.hostShaped, whole) ? [whole] : [])
	}

	private func unknownHosts(in text: String) throws -> [String] {
		try hosts(in: text).filter { host in
			!KnownHost.all.contains { $0.name.hasSameUnits(as: host) }
		}
	}

	private func checkKnownHosts(_ product: [SourceFile], spec: ProjectSpec) throws {
		let rule = "known-hosts"
		for file in product
		where !file.file.hasUnitSuffix("DebugView.swift")
			&& !file.file.hasUnitSuffix(".generated.swift")
		{
			for literal in try patterns.matchAll(
				#"(#+)?("""[\s\S]*?"""|"(?:\\.|[^"\\\n])*")\1"#, file.text)
			{
				let body = literal.groups[2]
				let quote = body.hasUnitPrefix("\"\"\"") ? 3 : 1
				let content = String(body.dropFirst(quote).dropLast(quote))
				for host in try unknownHosts(in: content) {
					try findings.report(file.file, rule, key: host)
				}
			}
		}
		let settings =
			spec.lines(under: ["settings"]) + spec.lines(under: ProjectSpec.app + ["settings"])
		for property in spec.lines(under: ProjectSpec.app + ["info", "properties"]) {
			var values = [property.value]
			for reference in try patterns.matchAll(#"\$[({](\w+)[)}]"#, property.value) {
				values += settings.filter {
					$0.path.last.map { $0.hasSameUnits(as: reference.groups[1]) } ?? false
				}.map(\.value)
			}
			for value in values {
				for host in try unknownHosts(in: value) {
					try findings.report(Self.appProject, rule, key: host)
				}
			}
		}
	}

	private func checkNotice(_ notice: SourceFile?, sources: [SourceFile]) throws {
		let rule = "notice-iphone-line"
		let lines = notice?.text.split(separator: "\n").map(String.init) ?? []
		if !lines.contains(where: { $0.hasSameUnits(as: Self.noticeIPhoneLine) }) {
			try findings.report(Self.notice, rule, key: "missing")
		}
		for source in sources
		where source.file.hasUnitPrefix("apps/") || source.file.hasUnitPrefix("packages/") {
			guard let named = try patterns.exec(Self.shippedNames, source.text) else { continue }
			try findings.report(source.file, rule, key: named.groups[1])
		}
	}
}
