import ToolSupport

struct SimFailure: DescribedFailure {
	let description: String
}

struct SimOptions: Equatable {
	let command: String?
	let arguments: [String]
	let buildFolder: String
	let shards: Int
	let timings: String?

	static func parse(
		_ argv: [String], environment: [String: String], repo: String, directory: String
	) throws -> SimOptions {
		var values: [(flag: String, value: String?)] = [
			(
				"--build-folder",
				environment["ENDURAGENT_VERIFY_BUILD"] ?? NodePath.join(repo, "DerivedData")
			),
			("--shards", "1"),
			("--timings", nil),
		]
		var arguments: [String] = []
		var index = 0
		while index < argv.count {
			let argument = argv[index]
			index += 1
			guard let flag = values.firstIndex(where: { $0.flag.hasSameUnits(as: argument) }) else {
				arguments.append(argument)
				continue
			}
			guard index < argv.count, !argv[index].isEmpty, !argv[index].hasUnitPrefix("-") else {
				throw SimFailure(description: "\(argument) needs a value")
			}
			values[flag].value = argv[index]
			index += 1
		}
		let shards = JavaScriptNumber.parse(values[1].value ?? "")
		guard shards == shards.rounded(), shards >= 1, shards <= 9_007_199_254_740_991 else {
			throw SimFailure(description: "--shards must be a positive whole number")
		}
		let timings = values[2].value.flatMap { $0.isEmpty ? nil : NodePath.resolve(directory, $0) }
		return SimOptions(
			command: arguments.first, arguments: Array(arguments.dropFirst()),
			buildFolder: NodePath.resolve(directory, values[0].value ?? ""), shards: Int(shards),
			timings: timings)
	}
}
