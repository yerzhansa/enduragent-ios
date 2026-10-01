import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct ChromeCatalogTests {
	@Test(arguments: [
		(
			LanguageTag.en, "Menu", "12 credits",
			"Requesting starter credits",
			"Added 12 credits",
			"This device already used its starter credits."
		),
		(
			LanguageTag.da, "Menu", "12 kreditter",
			"Anmoder om startkreditter",
			"Tilføjede 12 kreditter",
			"Denne enhed har allerede brugt sine startkreditter."
		),
		(
			LanguageTag.de, "Menü", "12 Guthabenpunkte",
			"Startguthaben wird angefordert",
			"12 Guthabenpunkte hinzugefügt",
			"Dieses Gerät hat sein Startguthaben bereits verwendet."
		),
		(
			LanguageTag.es, "Menú", "12 créditos",
			"Solicitando créditos iniciales",
			"Se añadieron 12 créditos",
			"Este dispositivo ya utilizó sus créditos iniciales."
		),
		(
			LanguageTag.fi, "Valikko", "12 krediittiä",
			"Pyydetään aloituskrediittejä",
			"Lisätty 12 krediittiä",
			"Tämä laite on jo käyttänyt aloituskrediittinsä."
		),
		(
			LanguageTag.fr, "Menu", "12 crédits",
			"Demande des crédits de départ",
			"12 crédits ajoutés",
			"Cet appareil a déjà utilisé ses crédits de départ."
		),
		(
			LanguageTag.it, "Menu", "12 crediti",
			"Richiesta dei crediti iniziali",
			"12 crediti aggiunti",
			"Questo dispositivo ha già utilizzato i suoi crediti iniziali."
		),
		(
			LanguageTag.ja, "メニュー", "12クレジット",
			"初回クレジットをリクエスト中",
			"12クレジットを追加しました",
			"このデバイスはすでに初回クレジットを使用しています。"
		),
		(
			LanguageTag.ko, "메뉴", "12 크레딧",
			"시작 크레딧 요청 중",
			"12 크레딧 추가됨",
			"이 기기는 이미 시작 크레딧을 사용했습니다."
		),
		(
			LanguageTag.nb, "Meny", "12 kreditter",
			"Ber om startkreditter",
			"La til 12 kreditter",
			"Denne enheten har allerede brukt startkredittene sine."
		),
		(
			LanguageTag.nl, "Menu", "12 tegoedpunten",
			"Starttegoed aanvragen",
			"12 tegoedpunten toegevoegd",
			"Dit apparaat heeft het starttegoed al gebruikt."
		),
		(
			LanguageTag.pl, "Menu", "12 kredytów",
			"Wysyłanie prośby o kredyty na start",
			"Dodano 12 kredytów",
			"To urządzenie wykorzystało już swoje kredyty na start."
		),
		(
			LanguageTag.ptBR, "Menu", "12 créditos",
			"Solicitando créditos iniciais",
			"12 créditos adicionados",
			"Este dispositivo já usou seus créditos iniciais."
		),
		(
			LanguageTag.ptPT, "Menu", "12 créditos",
			"A pedir créditos iniciais",
			"12 créditos adicionados",
			"Este dispositivo já utilizou os seus créditos iniciais."
		),
		(
			LanguageTag.sv, "Meny", "12 krediter",
			"Begär startkrediter",
			"Lade till 12 krediter",
			"Den här enheten har redan använt sina startkrediter."
		),
		(
			LanguageTag.zhHans, "菜单", "12 积分",
			"正在申请初始积分",
			"已添加 12 积分",
			"此设备已使用过初始积分。"
		),
		(
			LanguageTag.zhHant, "選單", "12 點數",
			"正在申請初始點數",
			"已新增 12 點數",
			"此裝置已使用過初始點數。"
		),
	])
	func chromeFollowsTheCoachLanguage(
		tag: LanguageTag, menu: String, balance: String, progress: String, added: String,
		alreadyGranted: String
	) async throws {
		let coach = await makeCoach(transport: FakeModelTransport(), store: InMemoryRecordLog())
		try await coach.setLanguage(.fixed(tag))
		let book = await coach.languagePreference().phrasebook(device: .en)
		let vars = ["formattedCount": "12"]
		#expect(book.say(Catalog.chatMenu, [:]) == menu)
		#expect(book.say(Catalog.creditsBalance, count: 12, vars) == balance)
		#expect(book.say(Catalog.onboardingStarterProgress, [:]) == progress)
		#expect(book.say(Catalog.onboardingStarterAdded, count: 12, vars) == added)
		#expect(
			book.say(Catalog.onboardingStarterAlreadyGranted, [:]) == alreadyGranted)
	}

	@Test func creditsAndStarterTopUpUseThePolishPluralForms() {
		let book = LanguageTag.pl.phrasebook
		for (units, balance, added) in [
			(1, "1 kredyt", "Dodano 1 kredyt"),
			(3, "3 kredyty", "Dodano 3 kredyty"),
			(5, "5 kredytów", "Dodano 5 kredytów"),
		] {
			let vars = ["formattedCount": String(units)]
			#expect(book.say(Catalog.creditsBalance, count: units, vars) == balance)
			#expect(book.say(Catalog.onboardingStarterAdded, count: units, vars) == added)
		}
	}
}
