import Foundation
import Testing

@testable import GenerateCatalogs

struct CatalogGeneratorTests {
	@Test
	func writesTheCatalogKeysAndThePhrasebookForTheFixtureCatalogs() throws {
		let fixtures = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
		try withRepository { root in
			try FileManager.default.copyItem(
				at: fixtures.appendingPathComponent("catalogs"), to: catalogs(in: root))

			let summary = try CatalogGenerator(root: root).generate()

			#expect(summary == "11 leaves, 13 keys, 17 locales")
			#expect(
				try Data(contentsOf: root.appendingPathComponent(CatalogGenerator.swiftOutput))
					== Data(
						contentsOf: fixtures.appendingPathComponent(
							"expected/CatalogKey.generated.swift.txt")))
			#expect(
				try Data(contentsOf: root.appendingPathComponent(CatalogGenerator.phrasebookOutput))
					== Data(contentsOf: fixtures.appendingPathComponent("expected/Phrasebook.json"))
			)
		}
	}

	@Test(arguments: [
		RejectedCatalog(
			english: #"{"greeting": "Hello {{first name}}"}"#,
			failure: "Invalid substitution name first name"),
		RejectedCatalog(
			english: #"{"ride_title": "Ride", "rideTitle": "Ride"}"#,
			failure: "Duplicate Swift identifier rideTitle for rideTitle and ride_title"),
		RejectedCatalog(
			english: #"{"ride.title": "Ride"}"#, failure: "Invalid catalog property ride.title"),
		RejectedCatalog(
			english: #"{"9rides": "Rides"}"#, failure: "Invalid Swift identifier 9rides for 9rides"),
		RejectedCatalog(english: "{}", failure: "English catalog has no keys"),
		RejectedCatalog(
			english: #"{"rides": 9}"#, failure: "Invalid catalog JSON at character 10"),
		RejectedCatalog(
			english: #"{"ride": {"title": "Ride"}}"#,
			spanish: #"{"ride.title": "Paseo", "ride": {"title": "Vuelta"}}"#,
			failure: "Two values for ride.title in catalog es"),
		RejectedCatalog(
			english: #"{"ride": "\ud800"}"#, failure: "Invalid catalog JSON at character 17"),
		RejectedCatalog(
			english: #"{"ride": "Ride"}"#,
			spanish: "{\"caf\u{E9}\": \"Uno\", \"cafe\u{301}\": \"Dos\"}",
			failure: "Two values for cafe\u{301} in catalog es"),
	])
	func rejectsACatalogItCannotGenerateFrom(_ catalog: RejectedCatalog) throws {
		try withRepository { root in
			try FileManager.default.createDirectory(
				at: catalogs(in: root), withIntermediateDirectories: true)
			for tag in CatalogGenerator.tags {
				let text = tag == "es" ? catalog.spanish ?? catalog.english : catalog.english
				try Data(text.utf8).write(
					to: catalogs(in: root).appendingPathComponent("\(tag).json"))
			}

			let failure = try #require(throws: CatalogFailure.self) {
				try CatalogGenerator(root: root).generate()
			}

			#expect(failure.description == catalog.failure)
			#expect(
				!FileManager.default.fileExists(
					atPath: root.appendingPathComponent(CatalogGenerator.phrasebookOutput).path))
		}
	}

	@Test
	func writesATopLevelKeyNamedLikeAJavaScriptProperty() throws {
		try withRepository { root in
			try FileManager.default.createDirectory(
				at: catalogs(in: root), withIntermediateDirectories: true)
			for tag in CatalogGenerator.tags {
				try Data(#"{"__proto__": "Ride"}"#.utf8).write(
					to: catalogs(in: root).appendingPathComponent("\(tag).json"))
			}

			let summary = try CatalogGenerator(root: root).generate()

			#expect(summary == "1 leaves, 1 keys, 17 locales")
			let phrasebook = String(
				decoding: try Data(
					contentsOf: root.appendingPathComponent(CatalogGenerator.phrasebookOutput)),
				as: UTF8.self)
			#expect(phrasebook.contains(#""__proto__": {"#))
		}
	}

	private func catalogs(in root: URL) -> URL {
		root.appendingPathComponent(CatalogGenerator.catalogDirectory)
	}

	private func withRepository(_ body: (URL) throws -> Void) throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"generate-catalogs-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(
			at: root.appendingPathComponent("packages/i18n"), withIntermediateDirectories: true)
		let outcome = Result { try body(root) }
		try FileManager.default.removeItem(at: root)
		try outcome.get()
	}
}

struct RejectedCatalog: Sendable, CustomTestStringConvertible {
	let english: String
	var spanish: String?
	let failure: String

	var testDescription: String { failure }
}
