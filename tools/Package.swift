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
		.executable(name: "sim", targets: ["Sim"]),
	],
	targets: [
		.target(name: "ToolSupport"),
		.executableTarget(name: "CheckSource", dependencies: ["ToolSupport"]),
		.executableTarget(name: "GenerateCatalogs", dependencies: ["ToolSupport"]),
		.executableTarget(name: "Sim", dependencies: ["ToolSupport"]),
		.testTarget(name: "CheckSourceTests", dependencies: ["CheckSource", "ToolSupport"]),
	],
	swiftLanguageModes: [.v6]
)
