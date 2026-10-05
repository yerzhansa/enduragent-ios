// swift-tools-version: 6.2

import PackageDescription

let package = Package(
	name: "EnduragentTools",
	platforms: [
		.macOS(.v15)
	],
	products: [
		.executable(name: "generate-catalogs", targets: ["GenerateCatalogs"])
	],
	targets: [
		.executableTarget(name: "GenerateCatalogs"),
		.testTarget(
			name: "GenerateCatalogsTests",
			dependencies: ["GenerateCatalogs"],
			resources: [.copy("Fixtures")]
		),
	],
	swiftLanguageModes: [.v6]
)
