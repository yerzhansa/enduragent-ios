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
			let text = source.text
			let declarations = try patterns.matchAll(#"\bclass\s+(\w+)\s*:\s*XCTestCase\b"#, text)
			for (index, declaration) in declarations.enumerated() {
				let name = declaration.groups[1]
				let end =
					index + 1 < declarations.count
					? declarations[index + 1].index : text.utf16.count
				let body = text.slice(declaration.end, end)
				let methods = try patterns.matchAll(#"\bfunc\s+(test\w+)\s*\("#, body).map {
					$0.groups[1]
				}
				if classes[name] == nil { classNames.append(name) }
				classes[name] = ProofClass(file: source.file, methods: Set(methods))
			}
		}
		for source in sources where try patterns.test(Self.featureFile, source.file) {
			let references = try patterns.matchAll(
				#"\b[A-Z][A-Za-z0-9]*(?:Proof|Probe)\b"#, source.text
			).map(\.text)
			if references.contains(where: { classes[$0] == nil }) {
				try findings.report(source.file, "feature-proof-reference")
			}
			if !NodePath.basename(source.file).hasSameUnits(as: "README.md") {
				mapped.formUnion(references)
			}
			let selectors = try patterns.matchAll(
				#"\b([A-Z][A-Za-z0-9]*(?:Proof|Probe))\/(test\w+)\b"#, source.text)
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
