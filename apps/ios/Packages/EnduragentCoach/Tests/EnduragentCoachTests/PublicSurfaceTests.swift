#if os(macOS)
	import Foundation
	import Testing

	struct PublicSurfaceTests {
		@Test func publicSymbolsMatchTheDesignList() throws {
			let root = try apiRoot()
			let expected =
				try symbols(in: "PublicSurfaceDesign")
				+ symbols(in: "PublicSurfaceAppDependencies")
			let actual = (root.children ?? []).flatMap { $0.publicNames() }.sorted()
			let changes = actual.difference(from: expected.sorted())
			#expect(changes.isEmpty, "Public API declarations changed: \(Array(changes))")
			try checkImplementationFolders()
		}

		private func symbols(in resource: String) throws -> [String] {
			let url = try #require(
				Bundle.module.url(
					forResource: resource, withExtension: "txt", subdirectory: "Fixtures"))
			return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(
				String.init)
		}

		private func apiRoot() throws -> APINode {
			let modules = try moduleDirectory()
			let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
				"enduragent-public-surface-\(UUID().uuidString)")
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			defer {
				do {
					try FileManager.default.removeItem(at: directory)
				} catch {
					Issue.record("Could not remove API inspection output: \(error)")
				}
			}
			let output = directory.appendingPathComponent("api.json")
			let diagnostics = directory.appendingPathComponent("diagnostics.txt")
			try Data().write(to: diagnostics)
			let diagnosticFile = try FileHandle(forWritingTo: diagnostics)
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
			process.arguments = [
				"swift-api-digester", "-dump-sdk", "-module", "EnduragentCoach",
				"-I", modules.path, "-o", output.path,
				"-module-cache-path",
				modules.deletingLastPathComponent().appendingPathComponent("ModuleCache").path,
				"-abort-on-module-fail",
			]
			process.standardOutput = diagnosticFile
			process.standardError = diagnosticFile
			try process.run()
			process.waitUntilExit()
			try diagnosticFile.close()
			let message = try String(contentsOf: diagnostics, encoding: .utf8)
			try #require(process.terminationStatus == 0, "swift-api-digester failed: \(message)")
			return try JSONDecoder().decode(APIDump.self, from: Data(contentsOf: output)).root
		}

		private func moduleDirectory() throws -> URL {
			var directory = Bundle.module.bundleURL
				.deletingLastPathComponent()
			while directory.path != "/" {
				let modules = directory.appendingPathComponent("Modules")
				if FileManager.default.fileExists(
					atPath: modules.appendingPathComponent("EnduragentCoach.swiftmodule").path)
				{
					return modules
				}
				directory.deleteLastPathComponent()
			}
			throw APITestFailure.compiledModuleMissing
		}

		private func checkImplementationFolders() throws {
			let package = URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			let sources = package.appendingPathComponent("Sources/EnduragentCoach")
			let publicDeclaration = try NSRegularExpression(
				pattern:
					#"\b(?:public|open)\s+(?:(?:final|nonisolated|static|override|mutating|required|convenience)\s+)*(?:actor|class|struct|enum|protocol|typealias|func|var|let|init|subscript)\b"#
			)
			for folder in ["Loop", "Transport"] {
				for file in try swiftFiles(in: sources.appendingPathComponent(folder)) {
					let source = try String(contentsOf: file, encoding: .utf8)
					#expect(
						publicDeclaration.firstMatch(
							in: source, range: NSRange(source.startIndex..., in: source)) == nil,
						"Public declaration in \(folder)/\(file.lastPathComponent)")
				}
			}
			let declaration = try NSRegularExpression(
				pattern:
					#"\bpublic\s+(?:final\s+)?(?:actor|class|struct|enum|protocol|typealias)\s+(\w+)"#
			)
			var actual: Set<String> = []
			for file in try swiftFiles(in: sources.appendingPathComponent("Records")) {
				let source = try String(contentsOf: file, encoding: .utf8)
				for match in declaration.matches(
					in: source, range: NSRange(source.startIndex..., in: source))
				{
					let range = try #require(Range(match.range(at: 1), in: source))
					actual.insert(String(source[range]))
				}
			}
			let retained = try Set(symbols(in: "PublicSurfaceRecordDependencies"))
			#expect(
				actual == retained,
				"Records public declarations changed: \(actual.symmetricDifference(retained).sorted())"
			)
		}

		private func swiftFiles(in directory: URL) throws -> [URL] {
			var files: [URL] = []
			for entry in try FileManager.default.contentsOfDirectory(
				at: directory, includingPropertiesForKeys: [.isDirectoryKey])
			{
				if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
					files += try swiftFiles(in: entry)
				} else if entry.pathExtension == "swift" {
					files.append(entry)
				}
			}
			return files
		}
	}

	private struct APIDump: Decodable {
		let root: APINode

		enum CodingKeys: String, CodingKey {
			case root = "ABIRoot"
		}
	}

	private struct APINode: Decodable {
		let name: String
		let printedName: String
		let declKind: String?
		let moduleName: String?
		let isInternal: Bool?
		let isExternal: Bool?
		let implicit: Bool?
		let children: [APINode]?

		func publicNames(in parent: String = "") -> [String] {
			guard declKind != nil, declKind != "Import", moduleName == "EnduragentCoach",
				isInternal != true,
				isExternal != true, implicit != true
			else { return [] }
			let qualified = parent.isEmpty ? printedName : "\(parent).\(printedName)"
			return [qualified] + (children ?? []).flatMap { $0.publicNames(in: qualified) }
		}
	}

	private enum APITestFailure: Error {
		case compiledModuleMissing
	}
#endif
