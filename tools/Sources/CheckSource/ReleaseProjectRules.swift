import Foundation
import ToolSupport

struct ProjectSpec {
	struct Line {
		let path: [String]
		let value: String
	}

	static let app = ["targets", "Enduragent"]
	static let phoneTests = ["targets", "EnduragentPhoneTests"]
	static let phoneScheme = ["schemes", "EnduragentPhone"]

	let lines: [Line]

	init(_ text: String, patterns: JavaScriptPatterns) throws {
		var stack: [(indent: Int, key: String)] = []
		var lines: [Line] = []
		for raw in text.split(separator: "\n") {
			var indent = raw.prefix { $0 == " " }.count
			var rest = String(raw.dropFirst(indent))
			if rest.isEmpty || rest.hasUnitPrefix("#") { continue }
			while let top = stack.last, top.indent >= indent { stack.removeLast() }
			if rest.hasUnitPrefix("- ") {
				stack.append((indent, "-"))
				rest = String(rest.dropFirst(2))
				indent += 2
			}
			if let entry = try patterns.exec(##"^([^\s:'"#][^:]*?)\s*:(\s.*|)$"##, rest) {
				let key = entry.groups[1]
				lines.append(
					Line(path: stack.map(\.key) + [key], value: Self.scalar(entry.groups[2])))
				stack.append((indent, key))
			} else {
				lines.append(Line(path: stack.map(\.key), value: Self.scalar(rest)))
			}
		}
		self.lines = lines
	}

	private static func scalar(_ text: String) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		for quote in ["\"", "'"] where trimmed.count >= 2 {
			if trimmed.hasUnitPrefix(quote) && trimmed.hasUnitSuffix(quote) {
				return String(trimmed.dropFirst().dropLast())
			}
		}
		return trimmed
	}

	func values(_ path: [String]) -> [String] {
		lines.filter { $0.path == path }.map(\.value)
	}

	func lines(under prefix: [String]) -> [Line] {
		lines.filter { $0.path.starts(with: prefix) }
	}

	func keys(under prefix: [String]) -> [String] {
		lines.filter { $0.path.count == prefix.count + 1 && $0.path.starts(with: prefix) }
			.compactMap(\.path.last)
	}
}

extension SourceChecker {
	static let appProject = "apps/ios/project.yml"
	static let coachPackageManifest = "apps/ios/Packages/EnduragentCoach/Package.swift"
	static let coachPackage = "EnduragentCoach"

	func checkPackageDependencies(_ spec: ProjectSpec, _ manifest: SourceFile?) throws {
		let rule = "no-app-package-dependency"
		for name in spec.keys(under: ["packages"]) where !name.hasSameUnits(as: Self.coachPackage) {
			try findings.report(Self.appProject, rule, key: name)
		}
		for name in spec.values(ProjectSpec.app + ["dependencies", "-", "package"])
		where !name.hasSameUnits(as: Self.coachPackage) {
			try findings.report(Self.appProject, rule, key: name)
		}
		guard let manifest else {
			try findings.report(Self.coachPackageManifest, rule, key: "missing")
			return
		}
		let code = try patterns.withoutStrings(manifest.text)
		if try patterns.test(#"\.package\s*\("#, code) {
			try findings.report(manifest.file, rule, key: ".package(")
		}
		guard let package = try patterns.exec(#"\bPackage\s*\("#, code) else { return }
		for argument in try patterns.matchAll(#"\bdependencies\s*:"#, code)
		where argument.index > package.end
			&& bracketDepth(code.slice(package.end, argument.index)) == 0
		{
			try findings.report(manifest.file, rule, key: "dependencies")
		}
	}

	private func bracketDepth(_ text: String) -> Int {
		var depth = 0
		for unit in text.utf8 {
			switch unit {
			case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
			case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
			default: break
			}
			if depth < 0 { return depth }
		}
		return depth
	}

	func checkSupportedDevices(_ spec: ProjectSpec) throws {
		let rule = "supported-devices"
		let settings = spec.lines(under: ProjectSpec.app + ["settings"])
		func defined(_ key: String) -> [String] {
			settings.filter { $0.path.last.map { $0.hasSameUnits(as: key) } ?? false }.map(\.value)
		}
		let deployment =
			spec.values(ProjectSpec.app + ["deploymentTarget"]).first
			?? spec.values(["options", "deploymentTarget", "iOS"]).first ?? ""
		let deployments = [deployment] + defined("IPHONEOS_DEPLOYMENT_TARGET")
		if !deployments.allSatisfy({ $0.hasSameUnits(as: "26.0") }) {
			try findings.report(Self.appProject, rule, key: "deploymentTarget")
		}
		let families = defined("TARGETED_DEVICE_FAMILY")
		if families.isEmpty || !families.allSatisfy({ $0.hasSameUnits(as: "1") }) {
			try findings.report(Self.appProject, rule, key: "TARGETED_DEVICE_FAMILY")
		}
		let portrait = "UIInterfaceOrientationPortrait"
		let orientations = try spec.lines(under: ProjectSpec.app).flatMap {
			try patterns.matchAll(#"\bUIInterfaceOrientation\w*"#, $0.value).map(\.text)
		}
		let declared = defined("INFOPLIST_KEY_UISupportedInterfaceOrientations")
		if declared.isEmpty || !orientations.allSatisfy({ $0.hasSameUnits(as: portrait) }) {
			try findings.report(Self.appProject, rule, key: "UISupportedInterfaceOrientations")
		}
	}

	func checkPhoneTestsUnhosted(_ spec: ProjectSpec) throws {
		let rule = "phone-tests-unhosted"
		func isApplication(_ target: String) -> Bool {
			spec.values(["targets", target, "type"]).contains { $0.hasSameUnits(as: "application") }
		}
		if spec.lines(under: ProjectSpec.phoneTests + ["settings"]).contains(where: {
			$0.path.last.map { $0.hasSameUnits(as: "TEST_TARGET_NAME") } ?? false
		}) {
			try findings.report(Self.appProject, rule, key: "TEST_TARGET_NAME")
		}
		if spec.values(ProjectSpec.phoneTests + ["dependencies", "-", "target"]).contains(
			where: isApplication)
		{
			try findings.report(Self.appProject, rule, key: "dependencies")
		}
		if spec.keys(under: ProjectSpec.phoneScheme + ["build", "targets"]).contains(
			where: isApplication)
		{
			try findings.report(Self.appProject, rule, key: "schemes")
		}
	}
}
