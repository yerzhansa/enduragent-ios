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

		@Test func catalogGrowthPreservesBoundaryGate() throws {
			let catalog = try JSONDecoder().decode(
				APINode.self,
				from: Data(
					"""
					{"name":"Catalog","printedName":"Catalog","declKind":"Enum","moduleName":"EnduragentCoach","children":[{"name":"newKey","printedName":"newKey","declKind":"Var","moduleName":"EnduragentCoach"}]}
					""".utf8))
			#expect(catalog.publicNames().isEmpty)
		}

		@Test func nonCatalogGrowthStillChangesTheBoundary() throws {
			let coach = try JSONDecoder().decode(
				APINode.self,
				from: Data(
					"""
					{"name":"Coach","printedName":"Coach","declKind":"Class","moduleName":"EnduragentCoach","children":[{"name":"probe","printedName":"probe()","declKind":"Func","moduleName":"EnduragentCoach"}]}
					""".utf8))
			let changes = coach.publicNames().difference(from: ["Coach"])
			#expect(
				Array(changes) == [
					.insert(offset: 1, element: "Coach.probe()", associatedWith: nil)
				])
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

		@Test(arguments: [
			"public extension Coach { nonisolated func probe() -> Int { 0 } }",
			"public private(set) var probe: Int",
			"public lazy var probe = 0",
			#"public macro probe() = #externalMacro(module: "Macros", type: "Probe")"#,
			"public indirect enum Probe { case next(Probe) }",
			"public nonisolated(unsafe) var probe = 0",
			"public prefix func + (value: Probe) -> Probe { value }",
			"public postfix func + (value: Probe) -> Probe { value }",
			"public infix func + (left: Probe, right: Probe) -> Probe { left }",
			"public\nextension Coach { func probe() -> Int { 0 } }",
		])
		func publicDeclarationModifiersAreRecognized(_ source: String) throws {
			#expect(try publicDeclarations(in: source).count == 1)
		}

		@Test func recordMembersAreIndividuallyNamed() throws {
			let declarations = try publicDeclarations(
				in: "public struct Record { public var probe: Int }")
			#expect(declarations.map(\.description) == ["struct Record", "var probe"])
		}

		private func checkImplementationFolders() throws {
			let package = URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			let sources = package.appendingPathComponent("Sources/EnduragentCoach")
			for folder in ["Loop", "Transport", "Records"] {
				for file in try swiftFiles(in: sources.appendingPathComponent(folder)) {
					let declarations = try publicDeclarations(
						in: String(contentsOf: file, encoding: .utf8))
					if file == sources.appendingPathComponent("Transport/FinishReason.swift") {
						#expect(
							declarations.map(\.description) == ["enum FinishReason"],
							"FinishReason belongs to production transport and is exposed by app fixture ScriptedEvent."
						)
						continue
					}
					#expect(
						declarations.isEmpty,
						"Public declarations in \(folder)/\(file.lastPathComponent): \(declarations)"
					)
				}
			}
		}

		private func publicDeclarations(in source: String) throws -> [PublicSourceDeclaration] {
			let declaration = try NSRegularExpression(
				pattern:
					#"\b(?:public|open)\s+(?:[A-Za-z_]\w*(?:\s*\([^)]*\))?\s+)*?(actor|class|struct|enum|protocol|typealias|extension|func|macro|var|let|init|subscript)\b(?:\s+([^\s(:{=<]+))?"#
			)
			return try declaration.matches(
				in: source, range: NSRange(source.startIndex..., in: source)
			)
			.map { match in
				let kindRange = try #require(Range(match.range(at: 1), in: source))
				let nameRange = Range(match.range(at: 2), in: source)
				return PublicSourceDeclaration(
					kind: String(source[kindRange]),
					name: nameRange.map { String(source[$0]) } ?? "")
			}
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

	private struct PublicSourceDeclaration: CustomStringConvertible {
		let kind: String
		let name: String

		var description: String { name.isEmpty ? kind : "\(kind) \(name)" }
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
			guard !(parent.isEmpty && name == "Catalog") else { return [] }
			let qualified = parent.isEmpty ? printedName : "\(parent).\(printedName)"
			return [qualified] + (children ?? []).flatMap { $0.publicNames(in: qualified) }
		}
	}

	private enum APITestFailure: Error {
		case compiledModuleMissing
	}
#endif
