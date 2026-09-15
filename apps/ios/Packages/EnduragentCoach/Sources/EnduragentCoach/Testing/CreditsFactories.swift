import Foundation

extension Credits {
	public static func of(_ units: Int) -> Credits {
		Credits(units: units)
	}
}

extension CreditScale {
	public static func perUsd(_ creditsPerUsd: Int) -> CreditScale {
		CreditScale(creditsPerUsd: creditsPerUsd)
	}
}

extension CreditPack {
	public static func pack(id: String, credits: Credits) -> CreditPack {
		CreditPack(id: id, credits: credits)
	}
}

extension PackCatalog {
	public static func catalog(purchasesEnabled: Bool, scale: CreditScale, packs: [CreditPack]) -> PackCatalog {
		PackCatalog(purchasesEnabled: purchasesEnabled, scale: scale, packs: packs)
	}
}

extension CreditBalance {
	public static func balance(_ credits: Credits) -> CreditBalance {
		CreditBalance(credits: credits)
	}
}
