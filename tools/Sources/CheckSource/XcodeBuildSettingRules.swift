extension SourceChecker {
	private func readPlist(_ path: String) throws -> JSONValue {
		try JSONValue.parse(Tool.output("plutil", ["-convert", "json", "-o", "-", "--", path]))
	}

	func checkXcodeBuildSettings(_ file: String, _ path: String) throws {
		let plist = try readPlist(path)
		let objects = try plist.member("objects")
		let project = try objects.member(plist.member("rootObject"))
		func configurations(_ owner: JSONValue) throws -> [JSONValue] {
			try objects.member(owner.member("buildConfigurationList"))
				.member("buildConfigurations").elements().map { try objects.member($0) }
		}
		let shared = try configurations(project).map {
			(name: try $0.member("name"), settings: try $0.member("buildSettings"))
		}
		for id in try project.member("targets").elements() {
			let target = try objects.member(id)
			for configuration in try configurations(target) {
				let name = try configuration.member("name")
				let inherited =
					shared.last { $0.name.isSamePrimitive(as: name) }?.settings ?? .undefined
				let own = try configuration.member("buildSettings")
				func setting(_ key: String) throws -> JSONValue {
					for settings in [own, inherited] {
						guard case .object(let members) = settings,
							let member = members.first(where: { $0.key.hasSameUnits(as: key) })
						else { continue }
						return member.value
					}
					return .undefined
				}
				if try !setting("DEVELOPMENT_TEAM").isTruthy
					|| !setting("CODE_SIGN_STYLE").isString("Automatic")
					|| !setting("SWIFT_VERSION").isString("6.0")
				{
					try findings.report(file, "xcode-shared-build-settings")
				}
				guard
					try target.member("productType").isString("com.apple.product-type.application"),
					name.isString("DebugKeychainProof")
				else { continue }
				let entitlementPath = try setting("CODE_SIGN_ENTITLEMENTS")
				guard entitlementPath.isTruthy else {
					try findings.report(file, "keychain-proof-storage-isolation")
					continue
				}
				guard case .string(let relativePath) = entitlementPath else {
					throw JSONFailure(description: "CODE_SIGN_ENTITLEMENTS is not a path")
				}
				let entitlements = try readPlist(
					NodePath.resolve(NodePath.dirname(path), "..", relativePath))
				if try !isIsolatedProof(entitlements, bundle: setting("PRODUCT_BUNDLE_IDENTIFIER"))
				{
					try findings.report(file, "keychain-proof-storage-isolation")
				}
			}
		}
	}

	private func isIsolatedProof(_ entitlements: JSONValue, bundle: JSONValue) throws -> Bool {
		let groups = try entitlements.member("keychain-access-groups")
		guard bundle.isString("icu.enduragent.keychainproof"), case .array(let list) = groups,
			list.count == 1, list[0].isString("$(AppIdentifierPrefix)icu.enduragent.keychainproof")
		else { return false }
		guard case .object(let members) = entitlements else { return true }
		return try !members.contains {
			try patterns.test(#"^com\.apple\.developer\.(?:icloud|ubiquity)-"#, $0.key)
		}
	}
}
