// swift-tools-version: 6.2

import PackageDescription

let package = Package(
	name: "EnduragentCoach",
	platforms: [
		.iOS(.v26),
		.macOS(.v15),
	],
	products: [
		.library(name: "EnduragentCoach", targets: ["EnduragentCoach"]),
		.library(
			name: "EnduragentCoachFixtures", targets: ["EnduragentCoachFixtures"]),
	],
	targets: [
		.target(
			name: "EnduragentCoach",
			resources: [
				.copy("Resources/Phrasebook.json"),
				.copy("Loop/PromptResources"),
				.copy("Transport/BundledModels.json"),
			]
		),
		.target(name: "EnduragentCoachFixtures", dependencies: ["EnduragentCoach"]),
		.testTarget(
			name: "EnduragentCoachTests",
			dependencies: ["EnduragentCoach", "EnduragentCoachFixtures"],
			resources: [.copy("Fixtures")]
		),
	],
	swiftLanguageModes: [.v6]
)
