// swift-tools-version: 6.2

import PackageDescription

let package = Package(
	name: "EnduragentTools",
	platforms: [
		.macOS(.v15)
	],
	products: [
		.executable(name: "check-coverage", targets: ["CheckCoverage"]),
		.executable(name: "check-source", targets: ["CheckSource"]),
		.executable(name: "generate-catalogs", targets: ["GenerateCatalogs"]),
		.executable(name: "phone-check", targets: ["PhoneCheck"]),
		.executable(name: "sim", targets: ["Sim"]),
		.executable(name: "upgrade-stores", targets: ["UpgradeStores"]),
	],
	targets: [
		.target(name: "ToolSupport"),
		.executableTarget(name: "CheckCoverage", dependencies: ["ToolSupport"]),
		.testTarget(name: "CheckCoverageTests", dependencies: ["CheckCoverage", "ToolSupport"]),
		.executableTarget(name: "CheckSource", dependencies: ["ToolSupport"]),
		.testTarget(name: "CheckSourceTests", dependencies: ["CheckSource", "ToolSupport"]),
		.executableTarget(name: "GenerateCatalogs", dependencies: ["ToolSupport"]),
		.testTarget(
			name: "GenerateCatalogsTests",
			dependencies: ["GenerateCatalogs"],
			resources: [.copy("Fixtures")]
		),
		.executableTarget(name: "PhoneCheck", dependencies: ["ToolSupport"]),
		.executableTarget(name: "Sim", dependencies: ["ToolSupport"]),
		.executableTarget(
			name: "SimFixtureTool", dependencies: ["ToolSupport"], path: "Tests/SimFixtureTool"),
		.testTarget(
			name: "SimTests",
			dependencies: ["PhoneCheck", "Sim", "SimFixtureTool", "ToolSupport"],
			resources: [.copy("Fixtures")]
		),
		.testTarget(name: "SwiftLintRuleTests", dependencies: ["ToolSupport"]),
		.testTarget(name: "ToolSupportTests", dependencies: ["ToolSupport"]),
		.executableTarget(name: "UpgradeStores", dependencies: ["ToolSupport"]),
	],
	swiftLanguageModes: [.v6]
)
