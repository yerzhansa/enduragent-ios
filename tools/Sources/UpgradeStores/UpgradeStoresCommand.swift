import Foundation
import ToolSupport

struct UpgradeStoreFailure: DescribedFailure {
	let description: String
}

struct UpgradeStoreSeed {
	let fixture: String
	let commit: String
	let seed: String
	let destinationVariable: String
	let scenarios: [String]

	static let all = [
		UpgradeStoreSeed(
			fixture: "v1-upgrade", commit: "82254bbda75ba79b0156d7efd3deac223489b2b0",
			seed: "V1UpgradeStoreSeed", destinationVariable: "V1_UPGRADE_DESTINATION",
			scenarios: ["history", "review"]),
		UpgradeStoreSeed(
			fixture: "pre-vault-5de5c782", commit: "5de5c782689764543b6d12aa30690912b21f53ee",
			seed: "PreVaultStoreSeed", destinationVariable: "UPGRADE_STORE_DESTINATION",
			scenarios: [""]),
		UpgradeStoreSeed(
			fixture: "build-2bbe2ee", commit: "2bbe2ee52bb7e8e0df277ae978a89c39d780acf8",
			seed: "Build2bbe2eeStoreSeed", destinationVariable: "UPGRADE_STORE_DESTINATION",
			scenarios: [""]),
	]
}

@main
struct UpgradeStoresCommand {
	static let package = "apps/ios/Packages/EnduragentCoach"
	static let firstWeek = "apps/ios/Enduragent/Fixtures/FirstWeekFixture.swift"
	static let stores = ["synced-records.store", "local-records.store"]

	let root: String
	let files = FileManager.default

	static func main() throws {
		let names = Array(CommandLine.arguments.dropFirst())
		let seeds = names.compactMap { name in
			UpgradeStoreSeed.all.first { $0.fixture.hasSameUnits(as: name) }
		}
		guard !names.isEmpty, seeds.count == names.count else {
			let known = UpgradeStoreSeed.all.map(\.fixture).joined(separator: "|")
			try Console.complain("Usage: upgrade-stores <\(known)>...")
			exit(2)
		}
		do {
			guard let executable = Bundle.main.executablePath else {
				throw UpgradeStoreFailure(description: "cannot find the running tool")
			}
			let command = UpgradeStoresCommand(root: try Checkout.root(ofExecutable: executable))
			for seed in seeds {
				try command.regenerate(seed)
			}
		} catch {
			try Console.complain("upgrade-stores: \(Console.text(of: error))")
			exit(1)
		}
	}

	func regenerate(_ seed: UpgradeStoreSeed) throws {
		let scratch = NodePath.join(
			files.temporaryDirectory.path, "enduragent-upgrade-stores-\(UUID().uuidString)")
		try files.createDirectory(atPath: scratch, withIntermediateDirectories: false)
		let outcome = Result { try regenerate(seed, in: scratch) }
		try files.removeItem(atPath: scratch)
		try outcome.get()
	}

	private func regenerate(_ seed: UpgradeStoreSeed, in scratch: String) throws {
		let archive = NodePath.join(scratch, "frozen.tar")
		try require(
			"git",
			["-C", root, "archive", "--output", archive, seed.commit, Self.package, Self.firstWeek])
		try require("tar", ["-x", "-C", scratch, "-f", archive])
		let package = NodePath.join(scratch, Self.package)
		let tests = NodePath.join(package, "Tests/EnduragentCoachTests")
		try files.copyItem(
			atPath: NodePath.join(root, "tools/fixtures/\(seed.seed).swift"),
			toPath: NodePath.join(tests, "\(seed.seed).swift"))
		try files.copyItem(
			atPath: NodePath.join(scratch, Self.firstWeek),
			toPath: NodePath.join(tests, "FirstWeekFixture.swift"))
		let generated = NodePath.join(scratch, "stores")
		var environment = ProcessInfo.processInfo.environment
		environment["OPENROUTER_API_KEY"] = ""
		environment["INTERVALS_API_KEY"] = ""
		environment[seed.destinationVariable] = generated
		try require(
			"swift",
			["test", "--disable-sandbox", "--package-path", package, "--filter", seed.seed],
			environment: environment)
		let fixtures = NodePath.join(root, Self.package, "Tests/EnduragentCoachTests/Fixtures")
		for scenario in seed.scenarios {
			let destination = NodePath.join(fixtures, seed.fixture, scenario)
			if files.fileExists(atPath: destination) { try files.removeItem(atPath: destination) }
			try files.createDirectory(atPath: destination, withIntermediateDirectories: true)
			for store in Self.stores {
				let source = NodePath.join(generated, scenario, store)
				try require("sqlite3", [source, "PRAGMA wal_checkpoint(TRUNCATE);"])
				try files.copyItem(atPath: source, toPath: NodePath.join(destination, store))
			}
		}
	}

	private func require(
		_ command: String, _ arguments: [String], environment: [String: String]? = nil
	) throws {
		let end = try Subprocess(environment: environment).run(
			command, arguments, output: .file(FileHandle.standardError))
		guard end.succeeded else {
			throw UpgradeStoreFailure(
				description:
					"\(command) \(arguments.joined(separator: " ")) exited \(end.statusText)")
		}
	}
}
