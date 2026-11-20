#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures

	extension FirstWeekFixture {
		static func install(
			_ method: FixtureAccessMethod, on secrets: ICloudKeychainStore,
			backing: FixtureSecretStoreBacking
		) throws {
			switch method {
			case .credits:
				try install(on: secrets)
			case .build9OpenRouter:
				try install(on: secrets)
				try backing.installBuild9OpenRouterChoice(
					model: ModelID(rawValue: "fixture/openrouter-model"),
					key: "fixture-openrouter-key")
			case .creditsNeedsSetup:
				_ = try secrets.prepareCreditsAccount()
			}
		}

		static func install(_ outcome: FixtureCreditsOutcome, on credits: FakeCreditsClient) {
			switch outcome {
			case .ready: break
			case .zero:
				credits.grantResult = .success(.minted(Credits(units: 0)))
				credits.balanceResult = .success(CreditBalance(credits: Credits(units: 0)))
			case .unavailable:
				credits.grantResult = .failure(.unavailable)
				credits.balanceResult = .failure(.unavailable)
			case .provisioningFailed:
				credits.grantResult = .failure(.unavailable)
				credits.balanceResult = .failure(.noAthleteKey)
			case .alreadyGranted:
				credits.grantResult = .success(.alreadyGranted)
			}
		}
	}
#endif
