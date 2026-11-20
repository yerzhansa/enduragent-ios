extension CreditBalance {
	public var notice: AthleteNotice? {
		credits.units <= 0 ? AthleteNotice(key: Catalog.creditsErrorExhausted, actions: []) : nil
	}
}
