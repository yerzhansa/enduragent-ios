import Foundation
import ToolSupport

final class Findings {
	private(set) var count = 0
	private let write: (String) throws -> Void

	init(write: @escaping (String) throws -> Void) {
		self.write = write
	}

	func report(_ file: String, _ rule: String, key: String? = nil) throws {
		count += 1
		try write("\(file.quotedAsJSON) [\(rule)]\(key.map { " \($0.quotedAsJSON)" } ?? "")")
	}
}

struct TrackedFiles {
	private let paths: Set<[UInt8]>

	init(_ paths: [String]) {
		self.paths = Set(paths.map { Array($0.utf8) })
	}

	func contains(_ path: String) -> Bool {
		paths.contains(Array(path.utf8))
	}

	func containsFile(under directory: String) -> Bool {
		let prefix = Array((directory + "/").utf8)
		return paths.contains { $0.starts(with: prefix) }
	}
}

struct SourceFailure: Error, CustomStringConvertible {
	let description: String
}

struct SourceChecker {
	static let fixture = #"^apps\/ios\/.*\/Tests\/.*\/Fixtures\/"#
	static let appIcon =
		#"^apps\/ios\/Enduragent\/Assets\.xcassets\/AppIcon\.appiconset\/AppIcon\.png$"#
	static let upgradeStore =
		#"^apps\/ios\/Packages\/EnduragentCoach\/Tests\/EnduragentCoachTests\/Fixtures\/"#
		+ #"(?:v1-upgrade\/(?:history|review)|pre-vault-5de5c782|build-2bbe2ee)\/"#
		+ #"(?:synced|local)-records\.store$"#
	static let proofFile = #"^apps\/ios\/EnduragentUITests\/[^/]+\.swift$"#
	static let featureFile = #"^\.agents\/skills\/verify-ios\/features\/[^/]+\.md$"#
	static let appSource = #"^apps\/ios\/Enduragent\/.*\.swift$"#
	static let forbiddenPath =
		#"(?:^|\/)(?:docs|node_modules|\.build|build|dist|out|DerivedData|\.wrangler|\.swiftpm"#
		+ #"|xcuserdata|\.idea)(?:\/|$)|(?:^|\/)(?:\.env(?:\.[^/]*)?|\.dev\.vars(?:\.[^/]*)?"#
		+ #"|credentials(?:\.[^/]*)?"#
		+ #"|[^/]+\.(?:p12|p8|mobileprovision|keychain|keychain-db|ipa|xcarchive))$"#
	static let sqliteHeader = Array("SQLite format 3\0".utf8)

	let root: String
	let patterns = JavaScriptPatterns()
	let findings: Findings

	func run() throws -> Int {
		let listing = try Tool.output("git", ["-C", root, "ls-files", "-z"])
		let files = listing.utf8.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
		let tracked = TrackedFiles(files.map { NodePath.resolve(root, $0) })
		var featureProofSources: [SourceFile] = []
		var appNavigationSources: [SourceFile] = []
		for file in files {
			guard let text = try readableText(file, tracked: tracked) else { continue }
			let source = SourceFile(file: file, text: text)
			if file.hasSameUnits(as: "apps/ios/Enduragent.xcodeproj/project.pbxproj") {
				try checkXcodeBuildSettings(file, NodePath.resolve(root, file))
			}
			if try patterns.test(Self.appSource, file) { appNavigationSources.append(source) }
			try checkTestRules(source)
			if try patterns.test(Self.proofFile, file) || patterns.test(Self.featureFile, file) {
				featureProofSources.append(source)
			}
			try checkContentRules(source)
		}
		try checkFeatureProofs(featureProofSources)
		try checkNavigationStacks(appNavigationSources)
		return files.count
	}

	private func readableText(_ file: String, tracked: TrackedFiles) throws -> String? {
		if try patterns.test(Self.forbiddenPath, file, ignoringCase: true) {
			try findings.report(file, "forbidden-path")
			return nil
		}
		let path = NodePath.resolve(root, file)
		guard path.hasUnitPrefix(root + "/") else {
			try findings.report(file, "unsafe-path")
			return nil
		}
		if try FileSystem.isSymbolicLink(path) {
			if try !isSafeTrackedLink(path, tracked) { try findings.report(file, "unsafe-path") }
			return nil
		}
		guard try FileSystem.realPath(path).hasUnitPrefix(root + "/") else {
			try findings.report(file, "unsafe-path")
			return nil
		}
		let bytes = try FileSystem.read(path)
		if bytes.contains(0) {
			let isStore =
				try patterns.test(Self.upgradeStore, file)
				&& bytes.prefix(16).elementsEqual(Self.sqliteHeader)
			if try !patterns.test(Self.appIcon, file) && !isStore {
				try findings.report(file, "unexpected-binary")
			}
			return nil
		}
		guard var text = String(validating: bytes, as: UTF8.self) else {
			throw SourceFailure(description: "\(file) is not UTF-8")
		}
		if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
		return text
	}

	private func isSafeTrackedLink(_ path: String, _ tracked: TrackedFiles) throws -> Bool {
		let resolved: String
		do {
			resolved = try FileSystem.realPath(path)
		} catch let failure as FileFailure where [ENOENT, ENOTDIR, ELOOP].contains(failure.code) {
			return false
		}
		guard resolved.hasSameUnits(as: root) || resolved.hasUnitPrefix(root + "/") else {
			return false
		}
		guard tracked.contains(resolved) || tracked.containsFile(under: resolved) else {
			return false
		}
		var pending = NodePath.segments(
			String(decoding: path.utf8.dropFirst(root.utf8.count + 1), as: UTF8.self))
		var current = root
		while !pending.isEmpty {
			let next = NodePath.resolve(current, pending.removeFirst())
			guard next.hasSameUnits(as: root) || next.hasUnitPrefix(root + "/") else {
				return false
			}
			if try FileSystem.isSymbolicLink(next) {
				guard tracked.contains(next) else { return false }
				let target = try FileSystem.linkTarget(next)
				if NodePath.isAbsolute(target) { return false }
				pending.insert(contentsOf: NodePath.segments(target), at: 0)
			} else {
				current = next
			}
		}
		return true
	}
}

struct SourceFile {
	let file: String
	let text: String
}
