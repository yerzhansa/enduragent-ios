import ToolSupport

extension SourceChecker {
	private struct ProofClass {
		let file: String
		let methods: Set<String>
	}

	func checkFeatureProofs(_ sources: [SourceFile]) throws {
		var classNames: [String] = []
		var classes: [String: ProofClass] = [:]
		var mapped: Set<String> = []
		for source in sources where try patterns.test(Self.proofFile, source.file) {
			let declarations = try SwiftDeclarations(code: source.text, patterns: patterns)
			for testCase in declarations.testCases {
				if classes[testCase.name] == nil { classNames.append(testCase.name) }
				classes[testCase.name] = ProofClass(file: source.file, methods: testCase.methods)
			}
		}
		for source in sources where try patterns.test(Self.featureFile, source.file) {
			let references = try patterns.matchAll(
				#"\b[A-Z][A-Za-z0-9]*(?:Proof|Probe|Sweep)\b"#, source.text
			).map(\.text)
			if references.contains(where: { classes[$0] == nil }) {
				try findings.report(source.file, "feature-proof-reference")
			}
			if !NodePath.basename(source.file).hasSameUnits(as: "README.md") {
				mapped.formUnion(references)
			}
			let selectors = try patterns.matchAll(
				#"\b([A-Z][A-Za-z0-9]*(?:Proof|Probe|Sweep))\/(test\w+)\b"#, source.text)
			for selector in selectors {
				let methods = classes[selector.groups[1]]?.methods ?? []
				if !methods.contains(selector.groups[2]) {
					try findings.report(source.file, "feature-proof-method")
				}
			}
		}
		for name in classNames where !mapped.contains(name) {
			if let proof = classes[name] {
				try findings.report(proof.file, "feature-proof-unmapped")
			}
		}
	}
}
