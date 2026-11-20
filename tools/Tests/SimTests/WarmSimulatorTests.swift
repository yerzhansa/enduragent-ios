import Foundation
import Testing
import ToolSupport

extension SimCommandTests {
	@Test(
		"warm saves its own simulator after it booted and shut down, and a new run boots from that data",
		.timeLimit(.minutes(2)))
	func aNewRunBootsFromTheWarmSimulator() throws {
		try withTree { fixture in
			let template = "\(fixture.root)/warm"
			let warmed = try fixture.sim(["warm", "--template", template])
			#expect(warmed.status == 0, "\(warmed.errors)")
			#expect(try fixture.read("\(template)/data/lifecycle") == "created booted shut down")
			#expect(
				try fixture.read("\(template)/template.json")
					== "{\n  \"runtime\": \"fixture-runtime\",\n  \"build\": \"23F77\",\n  \"deviceType\": \"iPhone 17e\"\n}\n"
			)
			#expect(try fixture.names(in: fixture.devices).isEmpty)
			let again = try fixture.sim(["warm", "--template", template])
			#expect(again.status == 1)
			#expect(again.errors.contains("never overwritten"))
			let created = try fixture.sim(
				["create", "seeded"], environment: ["ENDURAGENT_SIM_TEMPLATE": template])
			#expect(created.status == 0, "\(created.errors)")
			#expect(created.output.hasSuffix("\ntemplate \(template)\n"))
			#expect(
				try fixture.read("\(fixture.root)/booted-with")
					== "created\ncreated booted shut down\n")
			let run = try #require(
				try fixture.names(in: fixture.runs).first { $0.hasSuffix("-seeded") })
			let record = try JSONValue.parse(fixture.read("\(fixture.runs)/\(run)/run.json"))
			#expect(try record.member("template").isString(template))
		}
	}

	@Test(
		"a warm simulator from another runtime build is left out and the run boots a new simulator",
		.timeLimit(.minutes(2)))
	func aMismatchedWarmSimulatorIsLeftOut() throws {
		try withTree { fixture in
			let template = "\(fixture.root)/warm"
			try FileManager.default.createDirectory(
				atPath: "\(template)/data", withIntermediateDirectories: true)
			try fixture.write("warmed on another runtime", to: "\(template)/data/lifecycle")
			try fixture.write(
				#"{"runtime":"fixture-runtime","build":"23E254a","deviceType":"iPhone 17e"}"#,
				to: "\(template)/template.json")
			let created = try fixture.sim(["create", "unseeded", "--template", template])
			#expect(created.status == 0, "\(created.errors)")
			#expect(created.output.contains("booting a new simulator"))
			#expect(!created.output.contains("\ntemplate "))
			#expect(try fixture.read("\(fixture.root)/booted-with") == "created\n")
		}
	}
}
