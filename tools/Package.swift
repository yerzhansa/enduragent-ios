// swift-tools-version: 6.2

import PackageDescription

let package = Package(
	name: "EnduragentTools",
	platforms: [
		.macOS(.v15)
	],
	products: [
		.executable(name: "check-source", targets: ["CheckSource"]),
		.executable(name: "generate-catalogs", targets: ["GenerateCatalogs"]),
		.executable(name: "phone-check", targets: ["PhoneCheck"]),
		.executable(name: "sim", targets: ["Sim"]),
	],
	targets: [
		.target(name: "ToolSupport"),
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
	],
	swiftLanguageModes: [.v6]
)
